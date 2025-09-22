#!/bin/bash

# =============================================================================
# HELPERS.SH - Funções auxiliares para scripts de backup Percona
# =============================================================================
# Este arquivo contém funções comuns utilizadas pelos scripts de backup,
# restore e cleanup para evitar duplicação de código.
# =============================================================================

# -----------------------------------------------------------------------------
# Função para envio de webhooks
# -----------------------------------------------------------------------------
# Envia notificações via webhook para monitoramento externo
# Parâmetros:
#   $1: tipo (success, error, info)
#   $2: descrição breve
#   $3: mensagem detalhada
#   $4: código de erro (opcional)
#   $5: arquivo relacionado (opcional)
# -----------------------------------------------------------------------------
send_webhook() {
    local type="$1"
    local description="$2"
    local message="$3"
    local error_code="${4:-}"
    local file_name="${5:-}"
    
    # Verifica se webhooks estão habilitados
    if [[ "${WEBHOOK_ENABLED:-false}" != "true" ]]; then
        return 0
    fi
    
    # Verifica se URL do webhook está configurada
    if [[ -z "$WEBHOOK_URL" ]]; then
        echo "AVISO: WEBHOOK_URL não configurada, webhook ignorado"
        return 0
    fi
    
    # Monta payload JSON com campos opcionais
    local payload=$(cat <<EOF
{
    "type": "$type",
    "description": "$description",
    "message": "$message",
    "error_code": "$error_code",
    "file_name": "$file_name",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "hostname": "$(hostname)",
    "script": "$(basename "$0")"
}
EOF
)
    
    # Envia webhook
    if ! curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" > /dev/null 2>&1; then
        echo "ERRO: Falha ao enviar webhook para $WEBHOOK_URL"
    else
        echo "INFO: Webhook enviado - $type: $description"
    fi
}

# -----------------------------------------------------------------------------
# Sistema de checkpoints para controle de etapas
# -----------------------------------------------------------------------------

# Salva checkpoint de uma etapa com dados opcionais
save_checkpoint() {
    local step="$1"
    local status="${2:-completed}"
    local data="$3"
    local checkpoint_dir="${CHECKPOINT_DIR:-/tmp/backup_checkpoints}"
    local script_name=$(basename "$0" .sh)
    local today=$(date +%Y-%m-%d)
    local checkpoint_file="$checkpoint_dir/${script_name}_${today}_${step}.checkpoint"
    
    # Cria diretório se não existir
    mkdir -p "$checkpoint_dir"
    
    # Cria checkpoint com formato flexível
    {
        echo "timestamp=$(date -Iseconds)"
        echo "step=$step"
        echo "status=$status"
        echo "script=$script_name"
        echo "date=$today"
        
        # Adiciona variáveis específicas do script se existirem
        [[ -n "$BACKUP_TYPE" ]] && echo "backup_type=$BACKUP_TYPE"
        [[ -n "$DATE" ]] && echo "backup_date=$DATE"
        [[ -n "$TMP_DIR" ]] && echo "tmp_dir=$TMP_DIR"
        [[ -n "$ARCHIVE_PATH" ]] && echo "archive_path=$ARCHIVE_PATH"
        [[ -n "$FILENAME" ]] && echo "filename=$FILENAME"
        [[ -n "$BACKUP_FILE" ]] && echo "backup_file=$BACKUP_FILE"
        
        # Adiciona dados customizados se fornecidos
        [[ -n "$data" ]] && echo "data=$data"
    } > "$checkpoint_file"
    
    log_message "INFO" "Checkpoint salvo: $step -> $status"
}

# Verifica se uma etapa já foi concluída hoje
check_checkpoint() {
    local step="$1"
    local checkpoint_dir="${CHECKPOINT_DIR:-/tmp/backup_checkpoints}"
    local script_name=$(basename "$0" .sh)
    local today=$(date +%Y-%m-%d)
    local checkpoint_file="$checkpoint_dir/${script_name}_${today}_${step}.checkpoint"
    
    if [[ ! -f "$checkpoint_file" ]]; then
        return 1
    fi
    
    # Verifica se o status é completed
    local status=$(grep "^status=" "$checkpoint_file" 2>/dev/null | cut -d'=' -f2)
    [[ "$status" == "completed" ]]
}

# Obtém dados do checkpoint
get_checkpoint_data() {
    local step="$1"
    local field="${2:-data}"
    local checkpoint_dir="${CHECKPOINT_DIR:-/tmp/backup_checkpoints}"
    local script_name=$(basename "$0" .sh)
    local today=$(date +%Y-%m-%d)
    local checkpoint_file="$checkpoint_dir/${script_name}_${today}_${step}.checkpoint"
    
    if [[ ! -f "$checkpoint_file" ]]; then
        echo "not_found"
        return 1
    fi
    
    # Retorna o campo solicitado ou todo o conteúdo se field for "all"
    if [[ "$field" == "all" ]]; then
        cat "$checkpoint_file"
    else
        grep "^${field}=" "$checkpoint_file" 2>/dev/null | cut -d'=' -f2-
    fi
}

# Limpa checkpoints antigos ou do dia atual
cleanup_checkpoints() {
    local success="${1:-false}"
    local checkpoint_dir="${CHECKPOINT_DIR:-/tmp/backup_checkpoints}"
    local script_name=$(basename "$0" .sh)
    local today=$(date +%Y-%m-%d)
    
    if [[ ! -d "$checkpoint_dir" ]]; then
        return 0
    fi
    
    if [[ "$success" == "true" ]]; then
        # Remove checkpoints do dia atual após sucesso
        rm -f "$checkpoint_dir"/${script_name}_${today}_*.checkpoint
        log_message "INFO" "Checkpoints do dia limpos após sucesso"
    else
        # Remove checkpoints antigos (mais de 7 dias)
        find "$checkpoint_dir" -name "${script_name}_*.checkpoint" -mtime +7 -delete 2>/dev/null || true
        log_message "INFO" "Checkpoints antigos removidos"
    fi
}

# -----------------------------------------------------------------------------
# Validação de arquivos
# -----------------------------------------------------------------------------

# Valida se um arquivo existe e não está vazio
validate_file() {
    local file_path="$1"
    local min_size="${2:-1}"  # Tamanho mínimo em bytes (padrão: 1)
    
    if [[ ! -f "$file_path" ]]; then
        echo "ERRO: Arquivo não encontrado: $file_path"
        return 1
    fi
    
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo "0")
    
    if [[ "$file_size" -lt "$min_size" ]]; then
        echo "ERRO: Arquivo muito pequeno: $file_path ($file_size bytes)"
        return 1
    fi
    
    echo "INFO: Arquivo válido: $file_path ($file_size bytes)"
    return 0
}

# -----------------------------------------------------------------------------
# Limpeza de arquivos temporários
# -----------------------------------------------------------------------------

# Remove arquivos temporários do processo
cleanup_temp_files() {
    local temp_pattern="${1:-/tmp/backup_*}"
    
    echo "INFO: Limpando arquivos temporários..."
    
    # Remove arquivos temporários com padrão específico
    find /tmp -name "backup_*" -type f -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "restore_*" -type f -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "cleanup_*" -type f -mtime +1 -delete 2>/dev/null || true
    
    echo "INFO: Limpeza de arquivos temporários concluída"
}

# -----------------------------------------------------------------------------
# Utilitários gerais
# -----------------------------------------------------------------------------

# Converte bytes para formato legível
format_bytes() {
    local bytes="$1"
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    while [[ $bytes -gt 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        unit=$((unit + 1))
    done
    
    echo "${bytes}${units[$unit]}"
}

# Calcula duração em formato legível
format_duration() {
    local seconds="$1"
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

# Verifica se comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Log com timestamp
log_message() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# -----------------------------------------------------------------------------
# Função para obter modo de backup do ambiente
# -----------------------------------------------------------------------------
# Retorna o modo de backup configurado no ambiente
# Retorna:
#   "local" para backup local com XtraBackup (padrão)
#   "remote" para backup remoto com mydumper
# -----------------------------------------------------------------------------
get_backup_mode() {
    echo "${BACKUP_MODE:-local}"
}

# -----------------------------------------------------------------------------
# Função para detectar formato de backup
# -----------------------------------------------------------------------------
# Detecta o formato do backup considerando o modo (local/remoto) e arquivos
# Parâmetros:
#   $1: diretório do backup extraído
# Retorna:
#   "xtrabackup" para backups locais (modo local sempre usa xtrabackup)
#   "mydumper" para backups remotos (modo remoto sempre usa mydumper)
#   Se não conseguir determinar pelo modo, analisa arquivos no diretório
# -----------------------------------------------------------------------------
detect_backup_format() {
    local backup_dir="$1"
    
    if [[ ! -d "$backup_dir" ]]; then
        echo "unknown"
        return 1
    fi
    
    # Obtém o modo de backup configurado
    local backup_mode=$(get_backup_mode)
    
    # Determina formato baseado no modo configurado
    case "$backup_mode" in
        "local")
            # Modo local sempre usa xtrabackup
            echo "xtrabackup"
            return 0
            ;;
        "remote")
            # Modo remoto sempre usa mydumper
            echo "mydumper"
            return 0
            ;;
        *)
            # Se modo não está definido ou é inválido, detecta pelos arquivos
            ;;
    esac
    
    # Fallback: Detecção por análise de arquivos (compatibilidade com versões antigas)
    # Verifica se é backup xtrabackup (procura por arquivos característicos)
    if [[ -f "$backup_dir/xtrabackup_checkpoints" ]] || \
       [[ -f "$backup_dir/xtrabackup_info" ]] || \
       [[ -f "$backup_dir/backup-my.cnf" ]] || \
       [[ -d "$backup_dir/mysql" ]] || \
       [[ -f "$backup_dir/ibdata1" ]]; then
        echo "xtrabackup"
        return 0
    fi
    
    # Verifica se é backup mydumper (procura por arquivos .sql e metadata)
    if [[ -f "$backup_dir/metadata" ]] || \
       [[ $(find "$backup_dir" -name "*.sql" -type f | wc -l) -gt 0 ]] || \
       [[ -f "$backup_dir/mydumper.log" ]]; then
        echo "mydumper"
        return 0
    fi
    
    # Se não conseguir determinar nem pelo modo nem pelos arquivos, retorna unknown
    echo "unknown"
    return 1
}

# -----------------------------------------------------------------------------
# Inicialização
# -----------------------------------------------------------------------------

# Carrega variáveis de ambiente se arquivo .env existir
load_env() {
    local env_file="${1:-$(dirname "$0")/../.env}"
    
    if [[ -f "$env_file" ]]; then
        # Carrega apenas variáveis válidas (sem espaços em branco e comentários)
        while IFS= read -r line; do
            # Ignora linhas vazias e comentários
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            
            # Exporta variável se estiver no formato correto
            if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                export "$line"
            fi
        done < "$env_file"
        
        log_message "INFO" "Variáveis de ambiente carregadas de: $env_file"
    fi
}

# Inicialização automática
load_env

echo "INFO: Helpers carregados com sucesso - $(basename "$0")"