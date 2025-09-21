#!/bin/bash

# Carrega as variáveis de ambiente
source "$(dirname "$0")/../.env"

# Define o tipo de backup (full ou incremental)
BACKUP_TYPE=$1
if [[ -z "$BACKUP_TYPE" ]]; then
    DAY_OF_WEEK=$(date +%u)
    if [[ "$DAY_OF_WEEK" -eq 7 ]]; then
        BACKUP_TYPE="full"
    else
        BACKUP_TYPE="incremental"
    fi
fi

echo "Iniciando backup do tipo: $BACKUP_TYPE"

# Configurações de data e diretórios
DATE=$(date +%F_%H-%M-%S)
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
        return 1
    fi
    
    echo "Backup mydumper concluído em: $TMP_DIR"
    return 0
}

# Determina o método de backup baseado na configuração
determine_backup_method
USE_MYDUMPER=$?

# Realiza backup usando mydumper (remoto) ou Percona XtraBackup (local)
if [[ "$BACKUP_TYPE" == "full" ]]; then
    echo "Executando backup completo..."
    
    if [[ $USE_MYDUMPER -eq 1 ]]; then
        # Usa mydumper para backup remoto
        backup_with_mydumper
        BACKUP_SUCCESS=$?
    else
        # Backup completo usando xtrabackup (local)
        BACKUP_PARAMS=$(build_xtrabackup_params)
        
        if [[ -n "$BACKUP_PARAMS" ]]; then
            xtrabackup --backup \
                --user="$DB_USER" \
                --password="$DB_PASS" \
                --host="$DB_HOST" \
                --port="$DB_PORT" \
                --target-dir="$TMP_DIR" \
                --datadir="$DB_DATA_DIR" \
                $BACKUP_PARAMS
        else
            xtrabackup --backup \
                --user="$DB_USER" \
                --password="$DB_PASS" \
                --host="$DB_HOST" \
                --port="$DB_PORT" \
                --target-dir="$TMP_DIR" \
                --datadir="$DB_DATA_DIR"
        fi
        BACKUP_SUCCESS=$?
    fi
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao executar backup completo"
        
        # Envia webhook de erro
        if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
            curl -X POST -H "Content-Type: application/json" \
                 -d '{"event":"backup_error","type":"full","error":"xtrabackup failed","timestamp":"'"$(date -Iseconds)"'"}' \
                 "$WEBHOOK_URL" 2>/dev/null
        fi
        
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
else
    echo "Executando backup incremental..."
    
    # Verifica se backup incremental é compatível com as configurações
    if [[ $USE_MYDUMPER -eq 1 ]]; then
        echo "Aviso: Backup incremental não é suportado no modo remoto (mydumper)."
        echo "Executando backup completo com mydumper..."
        backup_with_mydumper
        BACKUP_SUCCESS=$?
        
        if [[ $BACKUP_SUCCESS -ne 0 ]]; then
            echo "Erro: Falha ao executar backup com mydumper"
            
            # Envia webhook de erro
            if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
                curl -X POST -H "Content-Type: application/json" \
                     -d '{"event":"backup_error","type":"incremental_fallback","error":"mydumper failed","timestamp":"'"$(date -Iseconds)"'"}' \
                     "$WEBHOOK_URL" 2>/dev/null
            fi
            
            rm -rf "$TMP_DIR"
            exit 1
        fi
    else
        # Busca o último backup completo no R2
        LATEST_FULL=$(aws s3 ls s3://$S3_BUCKET/$S3_FOLDER/ --endpoint-url "$S3_ENDPOINT" | grep full | sort | tail -n 1 | awk '{print $4}')
    
    if [[ -z "$LATEST_FULL" ]]; then
        echo "Erro: Nenhum backup completo encontrado. Abortando backup incremental."
        
        # Envia webhook de erro
        if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
            curl -X POST -H "Content-Type: application/json" \
                 -d '{"event":"backup_error","type":"incremental","error":"no full backup found","timestamp":"'"$(date -Iseconds)"'"}' \
                 "$WEBHOOK_URL" 2>/dev/null
        fi
        
        rm -rf "$TMP_DIR"
        exit 1
    fi
    
    echo "Usando backup base: $LATEST_FULL"
    
    # Baixa e extrai o backup completo base
    BASE_DIR="$TMP_BACKUP_PATH/base-backup-$DATE"
    mkdir -p "$BASE_DIR"
    
    aws s3 cp "s3://$S3_BUCKET/$S3_FOLDER/$LATEST_FULL" "$BASE_DIR/" --endpoint-url "$S3_ENDPOINT"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao baixar backup base do R2"
        rm -rf "$TMP_DIR" "$BASE_DIR"
        exit 1
    fi
    
    tar -xzf "$BASE_DIR/$LATEST_FULL" -C "$BASE_DIR"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao extrair backup base"
        rm -rf "$TMP_DIR" "$BASE_DIR"
        exit 1
    fi
    
    # Encontra o diretório do backup extraído
    BACKUP_BASE_DIR=$(find "$BASE_DIR" -type d -name "*-*-*_*-*-*" | head -n 1)
    if [[ -z "$BACKUP_BASE_DIR" ]]; then
        BACKUP_BASE_DIR="$BASE_DIR"
    fi
    
    # Executa backup incremental
    BACKUP_PARAMS=$(build_xtrabackup_params)
    
    if [[ -n "$BACKUP_PARAMS" ]]; then
        xtrabackup --backup \
            --user="$DB_USER" \
            --password="$DB_PASS" \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --target-dir="$TMP_DIR" \
            --incremental-basedir="$BACKUP_BASE_DIR" \
            --datadir="$DB_DATA_DIR" \
            $BACKUP_PARAMS
    else
        xtrabackup --backup \
            --user="$DB_USER" \
            --password="$DB_PASS" \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --target-dir="$TMP_DIR" \
            --incremental-basedir="$BACKUP_BASE_DIR" \
            --datadir="$DB_DATA_DIR"
    fi
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao executar backup incremental"
        
        # Envia webhook de erro
        if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
            curl -X POST -H "Content-Type: application/json" \
                 -d '{"event":"backup_error","type":"incremental","error":"xtrabackup incremental failed","timestamp":"'"$(date -Iseconds)"'"}' \
                 "$WEBHOOK_URL" 2>/dev/null
        fi
        
        rm -rf "$TMP_DIR" "$BASE_DIR"
        exit 1
    fi
    
    # Remove diretório base temporário
    rm -rf "$BASE_DIR"
    fi
fi

echo "Backup executado com sucesso. Criando arquivo compactado..."

# Compacta o backup com nível de compressão configurável
COMPRESSION=${COMPRESSION_LEVEL:-6}
echo "Compactando backup (nível de compressão: $COMPRESSION)..."
tar -cf - -C "$TMP_DIR" . | gzip -$COMPRESSION > "$ARCHIVE_PATH"

# Verifica se houve erro no tar ou no gzip
if [[ ${PIPESTATUS[0]} -ne 0 || ${PIPESTATUS[1]} -ne 0 ]]; then
    echo "Erro: Falha ao criar arquivo compactado"
    rm -rf "$TMP_DIR"
    exit 1
fi

echo "Enviando backup para R2..."

# Faz upload para o S3 com timeout configurável
TIMEOUT=${TRANSFER_TIMEOUT:-300}
echo "Fazendo upload do backup para o S3 (timeout: ${TIMEOUT}s)..."
timeout "$TIMEOUT" aws s3 cp "$ARCHIVE_PATH" "s3://$S3_BUCKET/$S3_FOLDER/$FILENAME" --endpoint-url "$S3_ENDPOINT"

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao enviar backup para R2"
    
    # Envia webhook de erro
    if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d '{"event":"backup_error","type":"'"$BACKUP_TYPE"'","error":"upload to R2 failed","timestamp":"'"$(date -Iseconds)"'"}' \
             "$WEBHOOK_URL" 2>/dev/null
    fi
    
    rm -rf "$TMP_DIR" "$ARCHIVE_PATH"
    exit 1
fi

echo "Backup enviado com sucesso!"

# Envia webhook de sucesso
if [[ "$WEBHOOK_EVENTS" == *"success"* ]]; then
    curl -X POST -H "Content-Type: application/json" \
         -d '{"event":"backup_success","type":"'"$BACKUP_TYPE"'","file":"'"$FILENAME"'","size":"'"$(stat -f%z "$ARCHIVE_PATH" 2>/dev/null || echo "unknown")"'","timestamp":"'"$(date -Iseconds)"'"}' \
         "$WEBHOOK_URL" 2>/dev/null
fi

# Limpeza dos arquivos temporários
echo "Limpando arquivos temporários..."
rm -rf "$TMP_DIR" "$ARCHIVE_PATH"

echo "Processo de backup finalizado com sucesso!"
