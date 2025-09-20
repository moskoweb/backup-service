#!/bin/bash

# Carrega as variáveis de ambiente
source "$(dirname "$0")/../.env"

# Verifica se o arquivo de backup foi fornecido
BACKUP_FILE=$1
if [[ -z "$BACKUP_FILE" ]]; then
    echo "Uso: $0 <arquivo_backup.tar.gz>"
    exit 1
fi

# Cria diretório temporário usando a variável do .env
TMP_DIR="$TMP_BACKUP_PATH/db-restore-$(date +%s)"
mkdir -p "$TMP_DIR"

echo "Iniciando processo de restore do backup: $BACKUP_FILE"

# Download do backup do R2/S3 com timeout configurável
TIMEOUT=${TRANSFER_TIMEOUT:-300}
echo "Baixando backup do R2 (timeout: ${TIMEOUT}s)..."
timeout "$TIMEOUT" aws s3 cp "s3://$S3_BUCKET/$S3_FOLDER/$BACKUP_FILE" "$TMP_DIR/" --endpoint-url "$S3_ENDPOINT"

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao baixar o backup do R2"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Extrai o arquivo de backup
echo "Extraindo arquivo de backup..."
tar -xzf "$TMP_DIR/$BACKUP_FILE" -C "$TMP_DIR"

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao extrair o arquivo de backup"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Para o serviço MySQL antes do restore
echo "Parando serviço MySQL..."
sudo systemctl stop mysql 2>/dev/null || sudo service mysql stop 2>/dev/null || true

# Prepara o backup usando xtrabackup (MySQL 8 compatível)
echo "Preparando backup com xtrabackup..."

# Procura pelo diretório de backup extraído
BACKUP_DIR=$(find "$TMP_DIR" -type d -name "*-*-*_*-*-*" | head -n 1)
if [[ -z "$BACKUP_DIR" ]]; then
    # Se não encontrar o padrão de data, procura por qualquer subdiretório
    BACKUP_DIR=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$TMP_DIR"
    fi
fi

echo "Usando diretório de backup: $BACKUP_DIR"

# Verifica se existe o arquivo xtrabackup_checkpoints (indicador de backup válido)
if [[ ! -f "$BACKUP_DIR/xtrabackup_checkpoints" ]]; then
    echo "Aviso: Arquivo xtrabackup_checkpoints não encontrado. Verificando estrutura do backup..."
    ls -la "$BACKUP_DIR"
fi

xtrabackup --prepare --target-dir="$BACKUP_DIR"

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao preparar o backup"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Remove dados antigos do MySQL (backup de segurança)
echo "Fazendo backup dos dados atuais..."
if [[ -d "$DB_DATA_DIR" ]]; then
    sudo mv "$DB_DATA_DIR" "$DB_DATA_DIR.backup.$(date +%s)"
fi

# Restaura os dados usando xtrabackup
echo "Restaurando dados do MySQL..."
sudo mkdir -p "$DB_DATA_DIR"
xtrabackup --copy-back --target-dir="$BACKUP_DIR" --datadir="$DB_DATA_DIR"

if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao restaurar os dados"
    # Restaura backup anterior se existir
    BACKUP_OLD=$(ls -1t "$DB_DATA_DIR".backup.* 2>/dev/null | head -n 1)
    if [[ -n "$BACKUP_OLD" ]]; then
        echo "Restaurando dados anteriores..."
        sudo rm -rf "$DB_DATA_DIR"
        sudo mv "$BACKUP_OLD" "$DB_DATA_DIR"
    fi
    rm -rf "$TMP_DIR"
    exit 1
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
    echo "Restore concluído com sucesso!"
    
    # Envia webhook de sucesso
    if [[ "$WEBHOOK_EVENTS" == *"restore"* ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d '{"event":"restore_success","file":"'"$BACKUP_FILE"'","timestamp":"'"$(date -Iseconds)"'"}' \
             "$WEBHOOK_URL" 2>/dev/null
    fi
else
    echo "Erro: MySQL não conseguiu iniciar após o restore"
    
    # Envia webhook de erro
    if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d '{"event":"restore_error","file":"'"$BACKUP_FILE"'","error":"MySQL failed to start","timestamp":"'"$(date -Iseconds)"'"}' \
             "$WEBHOOK_URL" 2>/dev/null
    fi
    
    rm -rf "$TMP_DIR"
    exit 1
fi

# Limpeza dos arquivos temporários
echo "Limpando arquivos temporários..."
rm -rf "$TMP_DIR"

echo "Processo de restore finalizado!"
