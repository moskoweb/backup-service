#!/bin/bash

# Carrega as variáveis de ambiente
source "$(dirname "$0")/../.env"

# Carrega funções auxiliares
source "$(dirname "$0")/helpers.sh"

# ===== CONFIGURAÇÕES ESPECÍFICAS DO BACKUP =====
# Diretório para armazenar checkpoints específicos do backup
CHECKPOINT_DIR="$TMP_BACKUP_PATH/.checkpoints"
mkdir -p "$CHECKPOINT_DIR"



# ===== SISTEMA DE PARÂMETROS =====
# Uso: backup.sh [tipo_backup] [--step=etapa]
# Etapas disponíveis: database, compression, upload, all
# Exemplos:
#   backup.sh full                    # Executa backup completo
#   backup.sh full --step=database    # Executa apenas backup do banco
#   backup.sh full --step=compression # Executa apenas compactação
#   backup.sh full --step=upload      # Executa apenas upload

# Processa parâmetros
BACKUP_TYPE=""
SPECIFIC_STEP=""

for arg in "$@"; do
    case $arg in
        --step=*)
            SPECIFIC_STEP="${arg#*=}"
            shift
            ;;
        full|incremental)
            BACKUP_TYPE="$arg"
            shift
            ;;
        --help|-h)
            echo "Uso: $0 [tipo_backup] [--step=etapa]"
            echo ""
            echo "Tipos de backup:"
            echo "  full         Backup completo"
            echo "  incremental  Backup incremental"
            echo ""
            echo "Etapas disponíveis (--step):"
            echo "  database     Executa apenas backup do banco de dados"
            echo "  compression  Executa apenas compactação"
            echo "  upload       Executa apenas upload para R2"
            echo "  all          Executa todas as etapas (padrão)"
            echo ""
            echo "Exemplos:"
            echo "  $0 full                    # Backup completo com todas as etapas"
            echo "  $0 full --step=database    # Apenas backup do banco"
            echo "  $0 incremental --step=upload # Apenas upload de backup incremental"
            exit 0
            ;;
        *)
            # Parâmetro desconhecido
            ;;
    esac
done

# Define tipo de backup padrão se não especificado
if [[ -z "$BACKUP_TYPE" ]]; then
    DAY_OF_WEEK=$(date +%u)
    if [[ "$DAY_OF_WEEK" -eq 7 ]]; then
        BACKUP_TYPE="full"
    else
        BACKUP_TYPE="incremental"
    fi
fi

# Define etapa padrão se não especificada
if [[ -z "$SPECIFIC_STEP" ]]; then
    SPECIFIC_STEP="all"
fi

# Valida etapa especificada
case "$SPECIFIC_STEP" in
    database|compression|upload|all)
        ;;
    *)
        echo "Erro: Etapa inválida '$SPECIFIC_STEP'"
        echo "Etapas válidas: database, compression, upload, all"
        exit 1
        ;;
esac

echo "Iniciando backup do tipo: $BACKUP_TYPE"
if [[ "$SPECIFIC_STEP" != "all" ]]; then
    echo "Executando apenas etapa: $SPECIFIC_STEP"
fi

# ===== FUNÇÕES MODULARES DAS ETAPAS =====

# Função para executar backup do banco de dados
execute_database_backup() {
    local step_name="database_backup"
    
    echo "=== ETAPA: BACKUP DO BANCO DE DADOS ==="
    
    # Verifica checkpoint
    if check_checkpoint "$step_name"; then
        echo "✓ Backup do banco já concluído, verificando arquivo..."
        if validate_file "$TMP_DIR" 100; then
            echo "✓ Dados do backup encontrados em: $TMP_DIR"
            return 0
        else
            echo "⚠ Checkpoint encontrado mas dados inválidos, refazendo backup do banco..."
        fi
    fi
    
    echo "Executando backup do banco de dados..."
    
    # Determina método de backup
    determine_backup_method
    local use_mydumper=$?
    
    local backup_success=1
    
    if [[ "$BACKUP_TYPE" == "full" ]]; then
        if [[ $use_mydumper -eq 1 ]]; then
            backup_with_mydumper
            backup_success=$?
        else
            # Backup completo usando xtrabackup
            local backup_params=$(build_xtrabackup_params)
            
            if [[ -n "$backup_params" ]]; then
                xtrabackup --backup \
                    --user="$DB_USER" \
                    --password="$DB_PASS" \
                    --host="$DB_HOST" \
                    --port="$DB_PORT" \
                    --target-dir="$TMP_DIR" \
                    $backup_params
            else
                xtrabackup --backup \
                    --user="$DB_USER" \
                    --password="$DB_PASS" \
                    --host="$DB_HOST" \
                    --port="$DB_PORT" \
                    --target-dir="$TMP_DIR"
            fi
            backup_success=$?
        fi
    else
        # Backup incremental
        if [[ $use_mydumper -eq 1 ]]; then
            echo "Aviso: Backup incremental não é suportado no modo remoto (mydumper)."
            echo "Executando backup completo com mydumper..."
            backup_with_mydumper
            backup_success=$?
        else
            # Lógica de backup incremental com xtrabackup
            execute_incremental_backup
            backup_success=$?
        fi
    fi
    
    if [[ $backup_success -ne 0 ]]; then
        echo "Erro: Falha ao executar backup do banco de dados"
        send_webhook "error" "Falha no backup do banco de dados" "Erro durante a execução do backup $BACKUP_TYPE" "B001"
        return 1
    fi
    
    # Salva checkpoint
    save_checkpoint "$step_name" "$(date -Iseconds)"
    echo "✓ Backup do banco de dados concluído com sucesso!"
    return 0
}

# Função para executar compactação
execute_compression() {
    local step_name="compression"
    
    echo "=== ETAPA: COMPACTAÇÃO ==="
    
    # Verifica checkpoint de compressão
    if check_checkpoint "$step_name"; then
        echo "✓ Compactação já concluída, verificando arquivo..."
        if validate_file "$ARCHIVE_PATH" 1048576; then
            echo "✓ Arquivo compactado encontrado: $ARCHIVE_PATH ($(stat -f%z "$ARCHIVE_PATH" 2>/dev/null || stat -c%s "$ARCHIVE_PATH" 2>/dev/null) bytes)"
            return 0
        else
            echo "⚠ Checkpoint encontrado mas arquivo inválido, refazendo compactação..."
        fi
    fi
    
    # Verifica se existe checkpoint de database e carrega as informações
    if check_checkpoint "database_backup"; then
        echo "Usando diretório de backup: $TMP_DIR"
    fi
    
    # Verifica se diretório de backup existe
    if [[ ! -d "$TMP_DIR" ]] || [[ ! "$(ls -A "$TMP_DIR" 2>/dev/null)" ]]; then
        echo "Erro: Diretório de backup não encontrado ou vazio: $TMP_DIR"
        echo "Execute primeiro: $0 $BACKUP_TYPE --step=database"
        return 1
    fi
    
    echo "Compactando backup..."
    local compression=${COMPRESSION_LEVEL:-6}
    echo "Compactando backup (nível de compressão: $compression)..."
    
    tar -cf - -C "$TMP_DIR" . | gzip -$compression > "$ARCHIVE_PATH"
    
    # Verifica se houve erro no tar ou no gzip
    if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
        echo "Erro: Falha ao criar arquivo compactado"
        send_webhook "error" "Falha na compactação do backup" "Erro durante a compactação do arquivo $FILENAME" "B002" "$FILENAME"
        return 1
    fi
    
    # Salva checkpoint
    save_checkpoint "$step_name" "$(stat -f%z "$ARCHIVE_PATH" 2>/dev/null || stat -c%s "$ARCHIVE_PATH" 2>/dev/null)"
    echo "✓ Compactação concluída com sucesso!"
    return 0
}

# Função para executar upload
execute_upload() {
    local step_name="upload"
    
    echo "=== ETAPA: UPLOAD PARA R2 ==="
    
    # Verifica checkpoint de upload
    if check_checkpoint "$step_name"; then
        echo "✓ Upload já concluído anteriormente"
        echo "Verificando se arquivo ainda existe no R2..."
        
        if aws s3 ls "s3://$S3_BUCKET/$FILENAME" --endpoint-url="$S3_ENDPOINT" --region="$S3_REGION" >/dev/null 2>&1; then
            echo "✓ Arquivo confirmado no R2!"
            return 0
        else
            echo "⚠ Checkpoint encontrado mas arquivo não está no R2, refazendo upload..."
        fi
    fi
    
    # Verifica se existe checkpoint de compressão e carrega as informações
    if check_checkpoint "compression"; then
        echo "Usando arquivo de backup: $ARCHIVE_PATH"
    elif check_checkpoint "database_backup"; then
        echo "Usando arquivo de backup: $ARCHIVE_PATH"
    fi
    
    # Verifica se arquivo compactado existe
    if [[ ! -f "$ARCHIVE_PATH" ]] || [[ ! -s "$ARCHIVE_PATH" ]]; then
        echo "Erro: Arquivo compactado não encontrado: $ARCHIVE_PATH"
        echo "Execute primeiro: $0 $BACKUP_TYPE --step=compression"
        return 1
    fi
    
    echo "Enviando backup para R2..."
    local timeout=${TRANSFER_TIMEOUT:-300}
    echo "Fazendo upload do backup para o S3 (timeout: ${timeout}s)..."
    
    timeout "$timeout" aws s3 cp "$ARCHIVE_PATH" "s3://$S3_BUCKET/$S3_FOLDER/$FILENAME" --endpoint-url "$S3_ENDPOINT"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao enviar backup para R2"
        send_webhook "error" "Falha no upload para R2" "Erro ao enviar arquivo $FILENAME para o bucket $S3_BUCKET" "B003" "$FILENAME"
        return 1
    fi
    
    # Salva checkpoint
    save_checkpoint "$step_name" "$(date -Iseconds)"
    echo "✓ Upload concluído com sucesso!"
    return 0
}

# Função para executar backup incremental
execute_incremental_backup() {
    echo "Executando backup incremental..."
    
    # Busca o backup completo mais recente no R2
    local latest_full=$(aws s3 ls "s3://$S3_BUCKET/$S3_FOLDER/" --endpoint-url="$S3_ENDPOINT" --region="$S3_REGION" | \
                       grep "full" | sort | tail -n 1 | awk '{print $4}')
    
    if [[ -z "$latest_full" ]]; then
        echo "Aviso: Nenhum backup completo encontrado. Mudando para backup completo..."
        BACKUP_TYPE="full"
        execute_database_backup
        return $?
    fi
    
    echo "Usando backup base: $latest_full"
    
    # Baixa e extrai o backup base
    local base_dir="$TMP_BACKUP_PATH/base-backup"
    mkdir -p "$base_dir"
    
    local timeout=${TRANSFER_TIMEOUT:-300}
    timeout "$timeout" aws s3 cp "s3://$S3_BUCKET/$S3_FOLDER/$latest_full" "$base_dir/$latest_full" --endpoint-url="$S3_ENDPOINT"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao baixar backup base do R2"
        send_webhook "error" "Falha no backup do banco de dados" "Erro ao baixar backup base $latest_full do R2 para backup incremental" "B001" "$latest_full"
        rm -rf "$base_dir"
        return 1
    fi
    
    # Extrai o backup base
    tar -xzf "$base_dir/$latest_full" -C "$base_dir"
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao extrair backup base"
        send_webhook "error" "Falha no backup do banco de dados" "Erro ao extrair backup base $latest_full para backup incremental" "B001" "$latest_full"
        rm -rf "$base_dir"
        return 1
    fi
    
    # Encontra o diretório do backup extraído
    local backup_base_dir=$(find "$base_dir" -type d -name "*-*-*_*-*-*" | head -n 1)
    if [[ -z "$backup_base_dir" ]]; then
        backup_base_dir="$base_dir"
    fi
    
    # Executa backup incremental
    local backup_params=$(build_xtrabackup_params)
    
    if [[ -n "$backup_params" ]]; then
        xtrabackup --backup \
            --user="$DB_USER" \
            --password="$DB_PASS" \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --target-dir="$TMP_DIR" \
            --incremental-basedir="$backup_base_dir" \
            --datadir="$DB_DATA_DIR" \
            $backup_params
    else
        xtrabackup --backup \
            --user="$DB_USER" \
            --password="$DB_PASS" \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --target-dir="$TMP_DIR" \
            --incremental-basedir="$backup_base_dir" \
            --datadir="$DB_DATA_DIR"
    fi
    
    local result=$?
    
    # Remove diretório base temporário
    rm -rf "$base_dir"
    
    return $result
}

# Configurações de data e diretórios
# Usa apenas a data (YYYY-MM-DD) para permitir múltiplas execuções no mesmo dia
DATE=$(date +%Y-%m-%d)
TMP_DIR="$TMP_BACKUP_PATH/db-backup-$DATE"
mkdir -p "$TMP_DIR"

# Define o destino do backup
# Usa prefixo personalizado se definido no .env
PREFIX=${BACKUP_PREFIX:-}

# Adiciona informação sobre banco específico no nome do arquivo
SUFFIX=""
if [[ -n "$DB_DATABASE" ]]; then
    SUFFIX="-${DB_DATABASE}"
fi

FILENAME="${PREFIX}${DATE}-${BACKUP_TYPE}${SUFFIX}.tar.gz"
ARCHIVE_PATH="$TMP_BACKUP_PATH/$FILENAME"

echo "Criando backup em: $TMP_DIR"

# ===== VERIFICAÇÕES DE RESUMO =====
echo "Verificando se existem checkpoints para resumir..."

# Verifica se já existe backup do banco concluído
if check_checkpoint "database_backup"; then
    echo "✓ Backup do banco já concluído, verificando arquivo..."
    if validate_file "$TMP_DIR" 100; then  # Verifica se diretório tem conteúdo
        echo "✓ Dados do backup encontrados em: $TMP_DIR"
        SKIP_DATABASE_BACKUP=true
    else
        echo "⚠ Checkpoint encontrado mas dados inválidos, refazendo backup do banco..."
        SKIP_DATABASE_BACKUP=false
    fi
else
    SKIP_DATABASE_BACKUP=false
fi

# Verifica se já existe arquivo compactado
if check_checkpoint "compression"; then
    echo "✓ Compactação já concluída, verificando arquivo..."
    if validate_file "$ARCHIVE_PATH" 1048576; then  # Mínimo 1MB para arquivo compactado
        echo "✓ Arquivo compactado encontrado: $ARCHIVE_PATH ($(stat -f%z "$ARCHIVE_PATH" 2>/dev/null || stat -c%s "$ARCHIVE_PATH" 2>/dev/null) bytes)"
        SKIP_COMPRESSION=true
    else
        echo "⚠ Checkpoint encontrado mas arquivo inválido, refazendo compactação..."
        SKIP_COMPRESSION=false
    fi
else
    SKIP_COMPRESSION=false
fi

# Verifica se upload já foi concluído
if check_checkpoint "upload"; then
    echo "✓ Upload já concluído anteriormente"
    echo "Verificando se arquivo ainda existe no R2..."
    
    # Tenta verificar se arquivo existe no R2
    if aws s3 ls "s3://$S3_BUCKET/$FILENAME" --endpoint-url="$S3_ENDPOINT" --region="$S3_REGION" >/dev/null 2>&1; then
        echo "✓ Arquivo confirmado no R2, backup já está completo!"
        cleanup_checkpoints "true"
        echo "Processo de backup finalizado com sucesso! (resumido)"
        exit 0
    else
        echo "⚠ Checkpoint encontrado mas arquivo não está no R2, refazendo upload..."
        SKIP_UPLOAD=false
    fi
else
    SKIP_UPLOAD=false
fi

echo "Resumo das etapas:"
echo "- Backup do banco: $([ "$SKIP_DATABASE_BACKUP" = true ] && echo "PULAR" || echo "EXECUTAR")"
echo "- Compactação: $([ "$SKIP_COMPRESSION" = true ] && echo "PULAR" || echo "EXECUTAR")"
echo "- Upload: $([ "$SKIP_UPLOAD" = true ] && echo "PULAR" || echo "EXECUTAR")"
echo ""

# Função para determinar o método de backup
determine_backup_method() {
    # Define o modo de backup (padrão: local)
    local mode=${BACKUP_MODE:-local}
    
    if [[ "$mode" == "remote" ]]; then
        echo "Modo remoto selecionado - usando mydumper/myloader"
        return 1  # Indica uso do mydumper
    else
        echo "Modo local selecionado - usando Percona XtraBackup"
        return 0  # Indica uso do xtrabackup
    fi
}

# Função para construir parâmetros do XtraBackup
build_xtrabackup_params() {
    local params=""
    
    # Se DB_DATABASE está definido, adiciona parâmetros para banco específico
    if [[ -n "$DB_DATABASE" ]]; then
        echo "Configurado para backup do banco: $DB_DATABASE"
        params="--databases=$DB_DATABASE"
    else
        echo "Fazendo backup completo de todos os bancos"
    fi
    
    echo "$params"
}

# Função para backup usando mydumper (para backup remoto)
backup_with_mydumper() {
    echo "Executando backup com mydumper..."
    
    # Constrói comando mydumper
    local mydumper_cmd="mydumper"
    mydumper_cmd+=" --host=$DB_HOST"
    mydumper_cmd+=" --port=$DB_PORT"
    mydumper_cmd+=" --user=$DB_USER"
    mydumper_cmd+=" --password=$DB_PASS"
    mydumper_cmd+=" --outputdir=$TMP_DIR"
    mydumper_cmd+=" --compress"
    mydumper_cmd+=" --events"
    mydumper_cmd+=" --routines"
    mydumper_cmd+=" --triggers"
    mydumper_cmd+=" --long-query-guard=3600"
    mydumper_cmd+=" --kill-long-queries"
    
    # Detecta número total de threads da máquina
    local cpu_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")
    
    # Otimizações de performance para backup remoto
    mydumper_cmd+=" --rows=10000"
    mydumper_cmd+=" --threads=$cpu_threads"
    mydumper_cmd+=" --build-empty-files"
    
    # Se DB_DATABASE está definido, faz backup apenas desse banco
    if [[ -n "$DB_DATABASE" ]]; then
        echo "Fazendo backup do banco específico: $DB_DATABASE"
        mydumper_cmd+=" --database=$DB_DATABASE"
    else
        echo "Fazendo backup de todos os bancos"
    fi
    
    # Executa o backup
    eval "$mydumper_cmd"
    local result=$?
    
    if [[ $result -ne 0 ]]; then
        echo "Erro: Falha ao executar mydumper"
        send_webhook "error" "Falha no backup do banco de dados" "Erro durante execução do mydumper para backup do banco de dados" "B001"
        return 1
    fi
    
    echo "Backup mydumper concluído em: $TMP_DIR"
    return 0
}

# Determina o método de backup baseado na configuração
determine_backup_method
USE_MYDUMPER=$?

# LÓGICA PRINCIPAL MODULAR COM CHECKPOINTS
# Executa apenas as etapas necessárias baseado nos checkpoints e parâmetros

# Execução baseada na etapa específica ou todas as etapas
if [[ "$SPECIFIC_STEP" == "all" ]]; then
    # Executa todas as etapas necessárias
    
    # 1. Backup do banco de dados
    if [[ "$SKIP_DATABASE_BACKUP" == "true" ]]; then
        echo "⏭ Pulando backup do banco (já concluído)"
    else
        if [[ "$BACKUP_TYPE" == "full" ]]; then
            execute_database_backup
        else
            # Backup incremental
            if [[ $USE_MYDUMPER -eq 1 ]]; then
                echo "Aviso: Backup incremental não é suportado no modo remoto (mydumper)."
                echo "Executando backup completo com mydumper..."
                execute_database_backup
            else
                execute_incremental_backup
            fi
        fi
        
        if [[ $? -ne 0 ]]; then
            echo "Erro: Falha no backup do banco de dados"
            exit 1
        fi
        
        save_checkpoint "backup" "$(date -Iseconds)"
    fi
    
    # 2. Compactação
    if [[ "$SKIP_COMPRESSION" == "true" ]]; then
        echo "⏭ Pulando compactação (já concluída)"
    else
        execute_compression
        if [[ $? -ne 0 ]]; then
            echo "Erro: Falha na compactação"
            exit 1
        fi
        save_checkpoint "compression" "$(date -Iseconds)"
    fi
    
    # 3. Upload
    if [[ "$SKIP_UPLOAD" == "true" ]]; then
        echo "⏭ Pulando upload (já concluído)"
    else
        execute_upload
        if [[ $? -ne 0 ]]; then
            echo "Erro: Falha no upload"
            exit 1
        fi
        save_checkpoint "upload" "$(date -Iseconds)"
    fi
    
else
    # Executa apenas a etapa específica
    echo "Executando apenas a etapa: $SPECIFIC_STEP"
    
    case "$SPECIFIC_STEP" in
        "backup")
            if [[ "$BACKUP_TYPE" == "full" ]]; then
                execute_database_backup
            else
                if [[ $USE_MYDUMPER -eq 1 ]]; then
                    echo "Aviso: Backup incremental não é suportado no modo remoto (mydumper)."
                    echo "Executando backup completo com mydumper..."
                    execute_database_backup
                else
                    execute_incremental_backup
                fi
            fi
            
            if [[ $? -eq 0 ]]; then
                save_checkpoint "backup" "$(date -Iseconds)"
                echo "✓ Backup concluído com sucesso!"
            else
                echo "✗ Falha no backup"
                exit 1
            fi
            ;;
        "compression")
            execute_compression
            if [[ $? -eq 0 ]]; then
                save_checkpoint "compression" "$(date -Iseconds)"
                echo "✓ Compactação concluída com sucesso!"
            else
                echo "✗ Falha na compactação"
                exit 1
            fi
            ;;
        "upload")
            execute_upload
            if [[ $? -eq 0 ]]; then
                save_checkpoint "upload" "$(date -Iseconds)"
                echo "✓ Upload concluído com sucesso!"
            else
                echo "✗ Falha no upload"
                exit 1
            fi
            ;;
    esac
    
    # Para etapas específicas, não continua com o resto do script
    echo "Etapa '$SPECIFIC_STEP' concluída. Finalizando..."
    exit 0
fi

# Envia webhook de sucesso
send_webhook "success" "Backup concluído com sucesso" "Backup $BACKUP_TYPE finalizado" "B000" "$FILENAME"

# Limpeza dos arquivos temporários
echo "Limpando arquivos temporários..."
rm -rf "$TMP_DIR" "$ARCHIVE_PATH"

# Limpa checkpoints após sucesso completo
cleanup_checkpoints "true"

echo "Processo de backup finalizado com sucesso!"
