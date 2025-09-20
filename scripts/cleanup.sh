#!/bin/bash

# Carrega as variáveis de ambiente
source "$(dirname "$0")/../.env"

echo "Iniciando processo de limpeza de backups antigos..."

# Calcula a data de corte baseada na variável RETENTION_DAYS do .env
CUTOFF_DATE=$(date -d "-$RETENTION_DAYS days" +%s 2>/dev/null || date -v "-${RETENTION_DAYS}d" +%s 2>/dev/null)

if [[ -z "$CUTOFF_DATE" ]]; then
    echo "Erro: Não foi possível calcular a data de corte"
    exit 1
fi

echo "Removendo backups anteriores a $(date -d "@$CUTOFF_DATE" 2>/dev/null || date -r "$CUTOFF_DATE" 2>/dev/null) (${RETENTION_DAYS} dias)"

# Contador de arquivos processados e removidos
TOTAL_FILES=0
DELETED_FILES=0
ERRORS=0

# Lista arquivos no R2/S3 e processa cada um
TIMEOUT=${TRANSFER_TIMEOUT:-300}
echo "Verificando arquivos no bucket S3 (timeout: ${TIMEOUT}s)..."
timeout "$TIMEOUT" aws s3 ls "s3://$S3_BUCKET/$S3_FOLDER/" --endpoint-url "$S3_ENDPOINT" 2>/dev/null | while read -r line; do
    # Extrai informações do arquivo
    FILE_DATE=$(echo "$line" | awk '{print $1, $2}')
    FILE_NAME=$(echo "$line" | awk '{print $4}')
    FILE_SIZE=$(echo "$line" | awk '{print $3}')
    
    # Pula linhas vazias ou inválidas
    if [[ -z "$FILE_NAME" || "$FILE_NAME" == "PRE" ]]; then 
        continue
    fi
    
    ((TOTAL_FILES++))
    
    # Converte data do arquivo para timestamp
    FILE_TIMESTAMP=$(date -d "$FILE_DATE" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$FILE_DATE" +%s 2>/dev/null)
    
    if [[ -z "$FILE_TIMESTAMP" ]]; then
        echo "Aviso: Não foi possível processar data do arquivo: $FILE_NAME"
        ((ERRORS++))
        continue
    fi
    
    # Verifica se o arquivo é mais antigo que a data de corte
    if (( FILE_TIMESTAMP < CUTOFF_DATE )); then
        echo "Removendo arquivo antigo: $FILE_NAME ($(date -d "@$FILE_TIMESTAMP" 2>/dev/null || date -r "$FILE_TIMESTAMP" 2>/dev/null))"
        
        # Remove o arquivo do R2/S3 com timeout
        timeout "$TIMEOUT" aws s3 rm "s3://$S3_BUCKET/$S3_FOLDER/$FILE_NAME" --endpoint-url "$S3_ENDPOINT" 2>/dev/null
        
        if [[ $? -eq 0 ]]; then
            ((DELETED_FILES++))
            echo "✓ Arquivo removido com sucesso: $FILE_NAME"
            
            # Envia webhook de limpeza se configurado
            if [[ "$WEBHOOK_EVENTS" == *"cleanup"* ]]; then
                curl -X POST -H "Content-Type: application/json" \
                     -d '{"event":"cleanup_deleted","file":"'"$FILE_NAME"'","size":"'"$FILE_SIZE"'","age_days":"'"$(( ($(date +%s) - FILE_TIMESTAMP) / 86400 ))"'","timestamp":"'"$(date -Iseconds)"'"}' \
                     "$WEBHOOK_URL" 2>/dev/null
            fi
        else
            echo "✗ Erro ao remover arquivo: $FILE_NAME"
            ((ERRORS++))
            
            # Envia webhook de erro se configurado
            if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
                curl -X POST -H "Content-Type: application/json" \
                     -d '{"event":"cleanup_error","file":"'"$FILE_NAME"'","error":"failed to delete","timestamp":"'"$(date -Iseconds)"'"}' \
                     "$WEBHOOK_URL" 2>/dev/null
            fi
        fi
    else
        echo "Mantendo arquivo: $FILE_NAME ($(date -d "@$FILE_TIMESTAMP" 2>/dev/null || date -r "$FILE_TIMESTAMP" 2>/dev/null))"
    fi
done

# Verifica se o comando aws s3 ls foi executado com sucesso
if [[ $? -ne 0 ]]; then
    echo "Erro: Falha ao listar arquivos no R2/S3"
    
    # Envia webhook de erro se configurado
    if [[ "$WEBHOOK_EVENTS" == *"error"* ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d '{"event":"cleanup_error","error":"failed to list files","timestamp":"'"$(date -Iseconds)"'"}' \
             "$WEBHOOK_URL" 2>/dev/null
    fi
    
    exit 1
fi

echo ""
echo "=== Resumo da Limpeza ==="
echo "Arquivos processados: $TOTAL_FILES"
echo "Arquivos removidos: $DELETED_FILES"
echo "Erros encontrados: $ERRORS"
echo "Retenção configurada: $RETENTION_DAYS dias"

# Envia webhook de resumo se configurado
if [[ "$WEBHOOK_EVENTS" == *"cleanup"* ]]; then
    curl -X POST -H "Content-Type: application/json" \
         -d '{"event":"cleanup_completed","total_files":"'"$TOTAL_FILES"'","deleted_files":"'"$DELETED_FILES"'","errors":"'"$ERRORS"'","retention_days":"'"$RETENTION_DAYS"'","timestamp":"'"$(date -Iseconds)"'"}' \
         "$WEBHOOK_URL" 2>/dev/null
fi

echo "Processo de limpeza finalizado!"
