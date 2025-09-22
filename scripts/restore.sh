#!/bin/bash

# Carrega as variáveis de ambiente
source "$(dirname "$0")/../.env"

# Carrega funções auxiliares
source "$(dirname "$0")/helpers.sh"

# ===== CONFIGURAÇÕES ESPECÍFICAS DO RESTORE =====
# Diretório para armazenar checkpoints específicos do restore
CHECKPOINT_DIR="$TMP_BACKUP_PATH/restore_checkpoints"
mkdir -p "$CHECKPOINT_DIR"

# Configurações específicas do restore
# -----------------------------------------------------------------------------
# As funções de checkpoint agora são fornecidas pelo helpers.sh
# e automaticamente detectam e incluem variáveis específicas do script

# SISTEMA DE PARÂMETROS
BACKUP_FILE=""
SPECIFIC_STEP="all"

# Processa argumentos da linha de comando
while [[ $# -gt 0 ]]; do
    case $1 in
        --step=*)
            SPECIFIC_STEP="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Uso: $0 [opções] <arquivo_backup.tar.gz>"
            echo ""
            echo "Opções:"
            echo "  --step=ETAPA     Executa apenas uma etapa específica"
            echo "                   Etapas disponíveis: download, extract, restore, all"
            echo "  --help, -h       Mostra esta ajuda"
            echo ""
            echo "Exemplos:"
            echo "  $0 backup_2024-01-15.tar.gz                    # Restore completo"
            echo "  $0 --step=download backup_2024-01-15.tar.gz    # Apenas download"
            echo "  $0 --step=extract backup_2024-01-15.tar.gz     # Apenas extração"
            echo "  $0 --step=restore backup_2024-01-15.tar.gz     # Apenas restore"
            exit 0
            ;;
        -*)
            echo "Erro: Opção desconhecida $1"
            echo "Use --help para ver as opções disponíveis"
            exit 1
            ;;
        *)
            if [[ -z "$BACKUP_FILE" ]]; then
                BACKUP_FILE="$1"
            else
                echo "Erro: Múltiplos arquivos especificados"
                exit 1
            fi
            shift
            ;;
    esac
done

# Verifica se o arquivo de backup foi fornecido
if [[ -z "$BACKUP_FILE" ]]; then
    echo "Erro: Arquivo de backup não especificado"
    echo "Uso: $0 [opções] <arquivo_backup.tar.gz>"
    echo "Use --help para mais informações"
    exit 1
fi

# Valida etapa especificada
case "$SPECIFIC_STEP" in
    "download"|"extract"|"restore"|"all")
        ;;
    *)
        echo "Erro: Etapa inválida '$SPECIFIC_STEP'"
        echo "Etapas válidas: download, extract, restore, all"
        exit 1
        ;;
esac

# Mostra etapa específica se não for 'all'
if [[ "$SPECIFIC_STEP" != "all" ]]; then
    echo "Executando apenas a etapa: $SPECIFIC_STEP"
fi

# Cria diretório temporário usando a variável do .env
TMP_DIR="$TMP_BACKUP_PATH/db-restore"
mkdir -p "$TMP_DIR"

# FUNÇÕES MODULARES PARA RESTORE

# Função para download do backup
execute_download() {
    echo "Executando download do backup: $BACKUP_FILE"
    
    # Verifica se já existe localmente
    if [[ -f "$TMP_DIR/$BACKUP_FILE" ]]; then
        echo "Arquivo já existe localmente, validando..."
        if validate_file "$TMP_DIR/$BACKUP_FILE"; then
            echo "✓ Arquivo local válido"
            return 0
        else
            echo "⚠ Arquivo local inválido, baixando novamente..."
            rm -f "$TMP_DIR/$BACKUP_FILE"
        fi
    fi
    
    # Download do backup do R2/S3 com timeout configurável
    local timeout=${TRANSFER_TIMEOUT:-300}
    echo "Baixando backup do R2 (timeout: ${timeout}s)..."
    timeout "$timeout" aws s3 cp "s3://$S3_BUCKET/$S3_FOLDER/$BACKUP_FILE" "$TMP_DIR/" --endpoint-url "$S3_ENDPOINT"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao baixar o backup do R2"
        send_webhook "error" "Falha no download do backup" "Erro ao baixar arquivo $BACKUP_FILE do bucket $S3_BUCKET" "R001" "$BACKUP_FILE"
        return 1
    fi
    
    # Valida arquivo baixado
    if ! validate_file "$TMP_DIR/$BACKUP_FILE"; then
        echo "Erro: Arquivo baixado está corrompido"
        send_webhook "error" "Falha no download do backup" "Arquivo $BACKUP_FILE baixado está corrompido ou inválido" "R001" "$BACKUP_FILE"
        return 1
    fi
    
    echo "✓ Download concluído com sucesso!"
    return 0
}

# Função para extração do backup
execute_extract() {
    echo "Executando extração do backup..."
    
    # Verifica se arquivo existe
    if [[ ! -f "$TMP_DIR/$BACKUP_FILE" ]]; then
        echo "Erro: Arquivo de backup não encontrado: $TMP_DIR/$BACKUP_FILE"
        return 1
    fi
    
    # Verifica se já foi extraído
    local backup_dir=$(find "$TMP_DIR" -type d -name "*-*-*_*-*-*" | head -n 1)
    if [[ -n "$backup_dir" && -f "$backup_dir/xtrabackup_checkpoints" ]]; then
        echo "✓ Backup já extraído em: $backup_dir"
        return 0
    fi
    
    # Extrai o arquivo de backup
    echo "Extraindo arquivo de backup..."
    tar -xzf "$TMP_DIR/$BACKUP_FILE" -C "$TMP_DIR"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao extrair o arquivo de backup"
        send_webhook "error" "Falha na extração do backup" "Erro ao extrair arquivo $BACKUP_FILE" "R002" "$BACKUP_FILE"
        return 1
    fi
    
    # Verifica se extração foi bem-sucedida
    backup_dir=$(find "$TMP_DIR" -type d -name "*-*-*_*-*-*" | head -n 1)
    if [[ -z "$backup_dir" ]]; then
        backup_dir=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        if [[ -z "$backup_dir" ]]; then
            backup_dir="$TMP_DIR"
        fi
    fi
    
    echo "Usando diretório de backup: $backup_dir"
    
    # Verifica se existe o arquivo xtrabackup_checkpoints
    if [[ ! -f "$backup_dir/xtrabackup_checkpoints" ]]; then
        echo "Aviso: Arquivo xtrabackup_checkpoints não encontrado. Verificando estrutura do backup..."
        ls -la "$backup_dir"
    fi
    
    echo "✓ Extração concluída com sucesso!"
    return 0
}

# Função para restore do banco
execute_restore() {
    echo "Executando restore do banco de dados..."
    
    # Encontra diretório do backup
    local backup_dir=$(find "$TMP_DIR" -type d -name "*-*-*_*-*-*" | head -n 1)
    if [[ -z "$backup_dir" ]]; then
        backup_dir=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        if [[ -z "$backup_dir" ]]; then
            backup_dir="$TMP_DIR"
        fi
    fi
    
    if [[ ! -d "$backup_dir" ]]; then
        echo "Erro: Diretório de backup não encontrado"
        return 1
    fi
    
    echo "Usando diretório de backup: $backup_dir"
    
    # Para o serviço MySQL antes do restore
    echo "Parando serviço MySQL..."
    sudo systemctl stop mysql 2>/dev/null || sudo service mysql stop 2>/dev/null || true
    
    # Prepara o backup usando xtrabackup
    echo "Preparando backup com xtrabackup..."
    xtrabackup --prepare --target-dir="$backup_dir"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao preparar o backup"
        send_webhook "error" "Falha no restore do backup" "Erro ao preparar backup com xtrabackup no diretório $backup_dir" "R003" "$BACKUP_FILE"
        return 1
    fi
    
    # Remove dados antigos do MySQL (backup de segurança)
    echo "Fazendo backup dos dados atuais..."
    if [[ -d "$DB_DATA_DIR" ]]; then
        sudo mv "$DB_DATA_DIR" "$DB_DATA_DIR.backup.$(date +%s)"
    fi
    
    # Restaura os dados usando xtrabackup
    echo "Restaurando dados do MySQL..."
    sudo mkdir -p "$DB_DATA_DIR"
    xtrabackup --copy-back --target-dir="$backup_dir" --datadir="$DB_DATA_DIR"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao restaurar os dados"
        send_webhook "error" "Falha no restore do backup" "Erro ao restaurar dados do MySQL para $DB_DATA_DIR" "R003" "$BACKUP_FILE"
        # Restaura backup anterior se existir
        local backup_old=$(ls -1t "$DB_DATA_DIR".backup.* 2>/dev/null | head -n 1)
        if [[ -n "$backup_old" ]]; then
            echo "Restaurando dados anteriores..."
            sudo rm -rf "$DB_DATA_DIR"
            sudo mv "$backup_old" "$DB_DATA_DIR"
        fi
        return 1
    fi
    
    # Ajusta permissões dos arquivos restaurados
    echo "Ajustando permissões..."
    sudo chown -R mysql:mysql "$DB_DATA_DIR"
    sudo chmod -R 750 "$DB_DATA_DIR"
    
    # Reinicia o serviço MySQL
    echo "Reiniciando serviço MySQL..."
    sudo systemctl start mysql 2>/dev/null || sudo service mysql start 2>/dev/null
    
    # Verifica se o MySQL iniciou corretamente
    sleep 5
    mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1;" > /dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        echo "✓ Restore concluído com sucesso!"
        return 0
    else
        echo "Erro: MySQL não conseguiu iniciar após o restore"
        return 1
    fi
}





echo "Iniciando processo de restore do backup: $BACKUP_FILE"

# LÓGICA PRINCIPAL MODULAR COM CHECKPOINTS

# Verifica se deve executar etapa específica ou todas
if [[ "$SPECIFIC_STEP" != "all" ]]; then
    echo "Executando etapa específica: $SPECIFIC_STEP"
    
    case "$SPECIFIC_STEP" in
        "download")
            if check_checkpoint "download"; then
                echo "✓ Etapa 'download' já foi concluída"
            else
                if execute_download; then
                    save_checkpoint "download" "completed"
                    echo "✓ Etapa 'download' concluída"
                else
                    echo "✗ Falha na etapa 'download'"
                    cleanup_temp_files
                    exit 1
                fi
            fi
            ;;
        "extract")
            if check_checkpoint "extract"; then
                echo "✓ Etapa 'extract' já foi concluída"
            else
                if execute_extract; then
                    save_checkpoint "extract" "completed"
                    echo "✓ Etapa 'extract' concluída"
                else
                    echo "✗ Falha na etapa 'extract'"
                    cleanup_temp_files
                    exit 1
                fi
            fi
            ;;
        "restore")
            if check_checkpoint "restore"; then
                echo "✓ Etapa 'restore' já foi concluída"
            else
                if execute_restore; then
                    save_checkpoint "restore" "completed"
                    echo "✓ Etapa 'restore' concluída"
                    send_webhook "success" "Restore concluído" "Restore do backup $BACKUP_FILE concluído com sucesso" "R000" "$BACKUP_FILE"
                else
                    echo "✗ Falha na etapa 'restore'"
                    cleanup_temp_files
                    exit 1
                fi
            fi
            ;;
        *)
            echo "Erro: Etapa '$SPECIFIC_STEP' não reconhecida"
            exit 1
            ;;
    esac
    
    echo "Etapa '$SPECIFIC_STEP' finalizada!"
    cleanup_temp_files
    exit 0
else
    echo "Executando processo completo de restore..."
    
    # Etapa 1: Download
    if check_checkpoint "download"; then
        echo "✓ Download já foi concluído, pulando..."
    else
        echo "Executando download..."
        if execute_download; then
            save_checkpoint "download" "completed"
            echo "✓ Download concluído"
        else
            echo "✗ Falha no download"
            cleanup_temp_files
            exit 1
        fi
    fi
    
    # Etapa 2: Extração
    if check_checkpoint "extract"; then
        echo "✓ Extração já foi concluída, pulando..."
    else
        echo "Executando extração..."
        if execute_extract; then
            save_checkpoint "extract" "completed"
            echo "✓ Extração concluída"
        else
            echo "✗ Falha na extração"
            cleanup_temp_files
            exit 1
        fi
    fi
    
    # Etapa 3: Restore
    if check_checkpoint "restore"; then
        echo "✓ Restore já foi concluído, pulando..."
    else
        echo "Executando restore..."
        if execute_restore; then
            save_checkpoint "restore" "completed"
            echo "✓ Restore concluído"
        else
            echo "✗ Falha no restore"
            cleanup_temp_files
            exit 1
        fi
    fi
    
    echo "✓ Processo completo de restore finalizado com sucesso!"
    send_webhook "success" "Processo de restore concluído" "Restore completo do backup $BACKUP_FILE finalizado com sucesso" "R000" "$BACKUP_FILE"
fi

# Limpeza de arquivos temporários e checkpoints
cleanup_temp_files
cleanup_checkpoints "true"

echo "Processo de restore finalizado!"
