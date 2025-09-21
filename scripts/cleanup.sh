#!/bin/bash

# Carrega variáveis de ambiente
source "$(dirname "$0")/../.env"

# SISTEMA DE CHECKPOINTS PARA CLEANUP

# Diretório para armazenar checkpoints
CHECKPOINT_DIR="$TMP_BACKUP_PATH/cleanup-checkpoints"
mkdir -p "$CHECKPOINT_DIR"

# Função para salvar checkpoint
save_checkpoint() {
    local step="$1"
    local status="$2"
    local checkpoint_file="$CHECKPOINT_DIR/cleanup-$(date +%Y-%m-%d)-$step.checkpoint"
    echo "$status|$(date -Iseconds)" > "$checkpoint_file"
    echo "Checkpoint salvo: $step -> $status"
}

# Função para verificar checkpoint
check_checkpoint() {
    local step="$1"
    local checkpoint_file="$CHECKPOINT_DIR/cleanup-$(date +%Y-%m-%d)-$step.checkpoint"
    
    if [[ -f "$checkpoint_file" ]]; then
        local status=$(cut -d'|' -f1 "$checkpoint_file")
        if [[ "$status" == "completed" ]]; then
            return 0  # Checkpoint existe e está completo
        fi
    fi
    return 1  # Checkpoint não existe ou não está completo
}

# Função para limpeza de checkpoints antigos
cleanup_checkpoints() {
    local force_cleanup="$1"
    
    if [[ "$force_cleanup" == "true" ]]; then
        echo "Limpando todos os checkpoints do dia..."
        rm -f "$CHECKPOINT_DIR"/cleanup-$(date +%Y-%m-%d)-*.checkpoint
    else
        # Remove checkpoints de mais de 7 dias
        find "$CHECKPOINT_DIR" -name "cleanup-*.checkpoint" -mtime +7 -delete 2>/dev/null
    fi
}

# Função para validação de arquivos
validate_file() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    # Verifica se arquivo não está vazio
    if [[ ! -s "$file_path" ]]; then
        return 1
    fi
    
    return 0
}

# SISTEMA DE PARÂMETROS

SPECIFIC_STEP="all"
SHOW_HELP=false

# Processa argumentos da linha de comando
while [[ $# -gt 0 ]]; do
    case $1 in
        --step)
            SPECIFIC_STEP="$2"
            shift 2
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Parâmetro desconhecido: $1"
            echo "Use --help para ver as opções disponíveis"
            exit 1
            ;;
    esac
done

# Mostra ajuda se solicitado
if [[ "$SHOW_HELP" == "true" ]]; then
    echo "Uso: $0 [opções]"
    echo ""
    echo "Opções:"
    echo "  --step ETAPA    Executa apenas uma etapa específica"
    echo "                  Etapas disponíveis: list, delete, verify"
    echo "  --help, -h      Mostra esta mensagem de ajuda"
    echo ""
    echo "Exemplos:"
    echo "  $0                    # Executa processo completo de limpeza"
    echo "  $0 --step list        # Executa apenas listagem de arquivos"
    echo "  $0 --step delete      # Executa apenas remoção de arquivos antigos"
    echo "  $0 --step verify      # Executa apenas verificação final"
    echo ""
    echo "Sistema de Checkpoints:"
    echo "  - Cada etapa é salva como checkpoint diário"
    echo "  - Etapas já concluídas são puladas automaticamente"
    echo "  - Checkpoints são limpos automaticamente após 7 dias"
    echo ""
    exit 0
fi

# Valida etapa específica se fornecida
if [[ "$SPECIFIC_STEP" != "all" ]]; then
    case "$SPECIFIC_STEP" in
        "list"|"delete"|"verify")
            echo "Executando etapa específica: $SPECIFIC_STEP"
            ;;
        *)
            echo "Erro: Etapa '$SPECIFIC_STEP' não é válida"
            echo "Etapas disponíveis: list, delete, verify"
            echo "Use --help para mais informações"
            exit 1
            ;;
    esac
fi

# FUNÇÕES MODULARES PARA CLEANUP

# Função para listagem de arquivos
execute_list() {
    echo "Executando listagem de arquivos no R2..."
    
    # Arquivo temporário para lista de arquivos
    local file_list="$TMP_BACKUP_PATH/cleanup-files-$(date +%s).txt"
    
    # Lista arquivos no R2/S3 com timeout configurável
    local timeout=${TRANSFER_TIMEOUT:-300}
    echo "Listando arquivos no R2 (timeout: ${timeout}s)..."
    
    timeout "$timeout" aws s3 ls "s3://$S3_BUCKET/$S3_FOLDER/" --endpoint-url "$S3_ENDPOINT" --recursive > "$file_list"
    
    if [[ $? -ne 0 ]]; then
        echo "Erro: Falha ao listar arquivos no R2"
        rm -f "$file_list"
        return 1
    fi
    
    # Verifica se arquivo de lista foi criado e não está vazio
    if ! validate_file "$file_list"; then
        echo "Erro: Lista de arquivos está vazia ou inválida"
        rm -f "$file_list"
        return 1
    fi
    
    # Conta total de arquivos
    local total_files=$(wc -l < "$file_list")
    echo "✓ Encontrados $total_files arquivos no R2"
    
    # Salva caminho do arquivo de lista para outras etapas
    echo "$file_list" > "$TMP_BACKUP_PATH/cleanup-file-list.path"
    
    echo "✓ Listagem concluída com sucesso!"
    return 0
}

# Função para remoção de arquivos antigos
execute_delete() {
    echo "Executando remoção de arquivos antigos..."
    
    # Recupera arquivo de lista
    local list_path_file="$TMP_BACKUP_PATH/cleanup-file-list.path"
    if [[ ! -f "$list_path_file" ]]; then
        echo "Erro: Lista de arquivos não encontrada. Execute primeiro a etapa 'list'"
        return 1
    fi
    
    local file_list=$(cat "$list_path_file")
    if ! validate_file "$file_list"; then
        echo "Erro: Arquivo de lista inválido"
        return 1
    fi
    
    # Calcula data de corte
    local cutoff_date=$(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d 2>/dev/null || date -v-"$RETENTION_DAYS"d +%Y-%m-%d 2>/dev/null)
    
    if [[ -z "$cutoff_date" ]]; then
        echo "Erro: Não foi possível calcular a data de corte"
        return 1
    fi
    
    echo "Data de corte para limpeza: $cutoff_date (retenção: $RETENTION_DAYS dias)"
    
    # Contadores
    local files_processed=0
    local files_removed=0
    local files_errors=0
    
    # Arquivo para log de remoções
    local removal_log="$TMP_BACKUP_PATH/cleanup-removals-$(date +%s).log"
    
    # Processa cada arquivo da lista
    while IFS= read -r line; do
        # Extrai informações do arquivo (formato: data hora tamanho nome)
        local file_date=$(echo "$line" | awk '{print $1}')
        local file_time=$(echo "$line" | awk '{print $2}')
        local file_size=$(echo "$line" | awk '{print $3}')
        local file_name=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
        
        files_processed=$((files_processed + 1))
        
        # Verifica se a data é válida e anterior à data de corte
        if [[ "$file_date" < "$cutoff_date" ]]; then
            echo "Removendo arquivo antigo: $file_name (data: $file_date)"
            
            # Remove arquivo do R2/S3 com timeout
            local timeout=${TRANSFER_TIMEOUT:-300}
            timeout "$timeout" aws s3 rm "s3://$S3_BUCKET/$S3_FOLDER/$file_name" --endpoint-url "$S3_ENDPOINT"
            
            if [[ $? -eq 0 ]]; then
                files_removed=$((files_removed + 1))
                echo "$(date -Iseconds)|REMOVED|$file_name|$file_size" >> "$removal_log"
                echo "✓ Arquivo removido: $file_name"
            else
                files_errors=$((files_errors + 1))
                echo "$(date -Iseconds)|ERROR|$file_name|$file_size" >> "$removal_log"
                echo "✗ Erro ao remover: $file_name"
            fi
        fi
        
        # Mostra progresso a cada 10 arquivos
        if [[ $((files_processed % 10)) -eq 0 ]]; then
            echo "Progresso: $files_processed arquivos processados..."
        fi
        
    done < "$file_list"
    
    # Salva estatísticas para verificação
    echo "$files_processed|$files_removed|$files_errors" > "$TMP_BACKUP_PATH/cleanup-stats.txt"
    echo "$removal_log" > "$TMP_BACKUP_PATH/cleanup-removal-log.path"
    
    echo "✓ Remoção concluída: $files_removed arquivos removidos, $files_errors erros"
    return 0
}

# Função para verificação final
execute_verify() {
    echo "Executando verificação final..."
    
    # Recupera estatísticas
    local stats_file="$TMP_BACKUP_PATH/cleanup-stats.txt"
    if [[ ! -f "$stats_file" ]]; then
        echo "Erro: Estatísticas não encontradas. Execute primeiro as etapas anteriores"
        return 1
    fi
    
    local stats=$(cat "$stats_file")
    local files_processed=$(echo "$stats" | cut -d'|' -f1)
    local files_removed=$(echo "$stats" | cut -d'|' -f2)
    local files_errors=$(echo "$stats" | cut -d'|' -f3)
    
    # Recupera log de remoções
    local log_path_file="$TMP_BACKUP_PATH/cleanup-removal-log.path"
    local removal_log=""
    if [[ -f "$log_path_file" ]]; then
        removal_log=$(cat "$log_path_file")
    fi
    
    echo "=== RESUMO DA LIMPEZA ==="
    echo "Arquivos processados: $files_processed"
    echo "Arquivos removidos: $files_removed"
    echo "Erros encontrados: $files_errors"
    
    if [[ -n "$removal_log" && -f "$removal_log" ]]; then
        echo "Log de remoções salvo em: $removal_log"
        
        # Mostra últimas remoções
        echo ""
        echo "Últimas remoções:"
        tail -5 "$removal_log" | while IFS='|' read -r timestamp action filename filesize; do
            if [[ "$action" == "REMOVED" ]]; then
                echo "  ✓ $filename ($filesize bytes) - $timestamp"
            elif [[ "$action" == "ERROR" ]]; then
                echo "  ✗ $filename ($filesize bytes) - $timestamp"
            fi
        done
    fi
    
    # Verifica se houve muitos erros
    if [[ $files_errors -gt 0 ]]; then
        local error_rate=$((files_errors * 100 / files_processed))
        if [[ $error_rate -gt 10 ]]; then
            echo "⚠ Taxa de erro alta: ${error_rate}% ($files_errors de $files_processed)"
            return 1
        fi
    fi
    
    echo "✓ Verificação concluída com sucesso!"
    return 0
}

# Função para envio de webhooks
send_webhook() {
    local event="$1"
    local message="$2"
    
    if [[ -n "$WEBHOOK_URL" && "$WEBHOOK_EVENTS" == *"$event"* ]]; then
        curl -X POST -H "Content-Type: application/json" \
             -d '{"event":"'"$event"'","message":"'"$message"'","timestamp":"'"$(date -Iseconds)"'"}' \
             "$WEBHOOK_URL" 2>/dev/null
    fi
}

# Função para limpeza de arquivos temporários
cleanup_temp_files() {
    echo "Limpando arquivos temporários..."
    rm -f "$TMP_BACKUP_PATH"/cleanup-files-*.txt
    rm -f "$TMP_BACKUP_PATH"/cleanup-removals-*.log
    rm -f "$TMP_BACKUP_PATH"/cleanup-*.path
    rm -f "$TMP_BACKUP_PATH"/cleanup-stats.txt
}

echo "Iniciando processo de limpeza de backups antigos..."

# EXECUÇÃO MODULAR BASEADA EM ETAPAS

# Função principal de execução
execute_cleanup_step() {
    local step="$1"
    
    case "$step" in
        "list")
            if check_checkpoint "list"; then
                echo "Etapa 'list' já foi concluída hoje. Pulando..."
                return 0
            fi
            
            if execute_list; then
                save_checkpoint "list" "completed"
                send_webhook "cleanup" "Listagem de arquivos concluída"
                return 0
            else
                save_checkpoint "list" "failed"
                send_webhook "error" "Falha na listagem de arquivos"
                return 1
            fi
            ;;
            
        "delete")
            if check_checkpoint "delete"; then
                echo "Etapa 'delete' já foi concluída hoje. Pulando..."
                return 0
            fi
            
            if execute_delete; then
                save_checkpoint "delete" "completed"
                send_webhook "cleanup" "Remoção de arquivos concluída"
                return 0
            else
                save_checkpoint "delete" "failed"
                send_webhook "error" "Falha na remoção de arquivos"
                return 1
            fi
            ;;
            
        "verify")
            if check_checkpoint "verify"; then
                echo "Etapa 'verify' já foi concluída hoje. Pulando..."
                return 0
            fi
            
            if execute_verify; then
                save_checkpoint "verify" "completed"
                send_webhook "cleanup" "Verificação final concluída"
                return 0
            else
                save_checkpoint "verify" "failed"
                send_webhook "error" "Falha na verificação final"
                return 1
            fi
            ;;
            
        *)
            echo "Erro: Etapa '$step' não reconhecida"
            return 1
            ;;
    esac
}

# Executa etapas baseado no parâmetro
if [[ "$SPECIFIC_STEP" == "all" ]]; then
    echo "Executando processo completo de limpeza..."
    
    # Executa todas as etapas em sequência
    for step in "list" "delete" "verify"; do
        echo ""
        echo "=== ETAPA: $step ==="
        
        if ! execute_cleanup_step "$step"; then
            echo "Erro: Falha na etapa '$step'. Interrompendo processo."
            cleanup_temp_files
            exit 1
        fi
    done
    
    echo ""
    echo "✓ Processo completo de limpeza finalizado com sucesso!"
    
else
    echo "Executando etapa específica: $SPECIFIC_STEP"
    
    if ! execute_cleanup_step "$SPECIFIC_STEP"; then
        echo "Erro: Falha na execução da etapa '$SPECIFIC_STEP'"
        cleanup_temp_files
        exit 1
    fi
    
    echo "✓ Etapa '$SPECIFIC_STEP' concluída com sucesso!"
fi

# Limpeza final de arquivos temporários
cleanup_temp_files

# Limpeza de checkpoints antigos
cleanup_checkpoints false

echo "Processo de limpeza finalizado!"
