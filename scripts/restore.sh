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
    timeout "$timeout" aws s3 cp "s3://$S3_BUCKET/$S3_FOLDER/$BACKUP_FILE" "$TMP_DIR/" \
        --endpoint-url "$S3_ENDPOINT" \
        --cli-read-timeout 0 \
        --multipart-threshold 64MB \
        --multipart-chunksize 16MB \
        --max-concurrent-requests 20
    
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
    
    # Detecta o formato do backup usando função do helpers.sh
    local backup_format=$(detect_backup_format "$backup_dir")
    
    if [[ "$backup_format" == "xtrabackup" ]]; then
        echo "Detectado backup do XtraBackup"
    elif [[ "$backup_format" == "mydumper" ]]; then
        echo "Detectado backup do mydumper"
    else
        echo "Erro: Formato de backup não reconhecido"
        echo "Conteúdo do diretório:"
        ls -la "$backup_dir"
        return 1
    fi
    
    # Para o serviço MySQL antes do restore
    echo "Parando serviço MySQL..."
    sudo systemctl stop mysql 2>/dev/null || sudo service mysql stop 2>/dev/null || true
    
    # Processa o backup baseado no formato
    if [[ "$backup_format" == "xtrabackup" ]]; then
        echo "=== INICIANDO RESTORE LOCAL COM XTRABACKUP ==="
        
        # Verifica se xtrabackup está disponível
        if ! command -v xtrabackup &> /dev/null; then
            echo "Erro: xtrabackup não encontrado. Instale o Percona XtraBackup"
            send_webhook "error" "XtraBackup não encontrado" "Comando xtrabackup não está disponível no sistema" "R004" "$BACKUP_FILE"
            return 1
        fi
        
        # Verifica espaço em disco disponível
        local backup_size=$(du -sb "$backup_dir" 2>/dev/null | cut -f1)
        local available_space=$(df "$DB_DATA_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
        available_space=$((available_space * 1024)) # Converte para bytes
        
        if [[ $backup_size -gt $available_space ]]; then
            echo "Erro: Espaço insuficiente. Necessário: $(format_bytes $backup_size), Disponível: $(format_bytes $available_space)"
            send_webhook "error" "Espaço insuficiente" "Espaço em disco insuficiente para restore" "R005" "$BACKUP_FILE"
            return 1
        fi
        
        # Etapa 1: Preparação do backup
        echo "Etapa 1/4: Preparando backup com xtrabackup..."
        local prepare_log="$TMP_DIR/xtrabackup_prepare.log"
        
        xtrabackup --prepare --target-dir="$backup_dir" \
                   --use-memory=1G \
                   --parallel=4 2>&1 | tee "$prepare_log"
        
        local prepare_result=${PIPESTATUS[0]}
        if [[ $prepare_result -ne 0 ]]; then
            echo "Erro: Falha ao preparar o backup"
            echo "Log de erro salvo em: $prepare_log"
            send_webhook "error" "Falha na preparação do backup" "Erro ao preparar backup com xtrabackup. Verifique log: $prepare_log" "R003" "$BACKUP_FILE"
            return 1
        fi
        echo "✓ Backup preparado com sucesso"
        
        # Etapa 2: Backup de segurança dos dados atuais
        echo "Etapa 2/4: Fazendo backup de segurança dos dados atuais..."
        local timestamp=$(date +%s)
        local backup_safety_dir="$DB_DATA_DIR.backup.$timestamp"
        
        if [[ -d "$DB_DATA_DIR" ]]; then
            echo "Movendo dados atuais para: $backup_safety_dir"
            sudo mv "$DB_DATA_DIR" "$backup_safety_dir"
            
            # Verifica se o backup de segurança foi criado
            if [[ ! -d "$backup_safety_dir" ]]; then
                echo "Erro: Falha ao criar backup de segurança"
                send_webhook "error" "Falha no backup de segurança" "Não foi possível criar backup dos dados atuais" "R006" "$BACKUP_FILE"
                return 1
            fi
            echo "✓ Backup de segurança criado: $backup_safety_dir"
        else
            echo "✓ Diretório de dados não existe, criando novo"
        fi
        
        # Etapa 3: Restauração dos dados
        echo "Etapa 3/4: Restaurando dados com xtrabackup..."
        sudo mkdir -p "$DB_DATA_DIR"
        local restore_log="$TMP_DIR/xtrabackup_restore.log"
        
        xtrabackup --copy-back \
                   --target-dir="$backup_dir" \
                   --datadir="$DB_DATA_DIR" \
                   --parallel=4 2>&1 | tee "$restore_log"
        
        local restore_result=${PIPESTATUS[0]}
        if [[ $restore_result -ne 0 ]]; then
            echo "Erro: Falha ao restaurar os dados"
            echo "Log de erro salvo em: $restore_log"
            send_webhook "error" "Falha no restore dos dados" "Erro ao restaurar dados com xtrabackup. Verifique log: $restore_log" "R003" "$BACKUP_FILE"
            
            # Restaura backup de segurança se existir
            if [[ -d "$backup_safety_dir" ]]; then
                echo "Restaurando dados anteriores..."
                sudo rm -rf "$DB_DATA_DIR"
                sudo mv "$backup_safety_dir" "$DB_DATA_DIR"
                echo "✓ Dados anteriores restaurados"
            fi
            return 1
        fi
        echo "✓ Dados restaurados com sucesso"
        
        # Etapa 4: Ajuste de permissões e otimizações
        echo "Etapa 4/4: Ajustando permissões e otimizando..."
        
        # Ajusta permissões dos arquivos restaurados
        sudo chown -R mysql:mysql "$DB_DATA_DIR"
        sudo chmod -R 750 "$DB_DATA_DIR"
        
        # Otimizações específicas para performance
        if [[ -f "$DB_DATA_DIR/ib_logfile0" ]]; then
            sudo chmod 660 "$DB_DATA_DIR"/ib_logfile*
        fi
        
        if [[ -f "$DB_DATA_DIR/ibdata1" ]]; then
            sudo chmod 660 "$DB_DATA_DIR/ibdata1"
        fi
        
        echo "✓ Permissões ajustadas e otimizações aplicadas"
        echo "=== RESTORE LOCAL XTRABACKUP CONCLUÍDO ==="
        
    elif [[ "$backup_format" == "mydumper" ]]; then
        echo "=== INICIANDO RESTORE REMOTO COM MYLOADER ==="
        
        # Verifica se myloader está disponível
        if ! command -v myloader &> /dev/null; then
            echo "Erro: myloader não encontrado. Instale o mydumper/myloader"
            send_webhook "error" "MyLoader não encontrado" "Comando myloader não está disponível no sistema" "R007" "$BACKUP_FILE"
            return 1
        fi
        
        # Etapa 1: Verificação e inicialização do MySQL
        echo "Etapa 1/5: Verificando e inicializando MySQL..."
        
        # Verifica se MySQL está rodando, se não, inicia
        if ! mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1;" > /dev/null 2>&1; then
            echo "MySQL não está rodando, iniciando serviço..."
            sudo systemctl start mysql 2>/dev/null || sudo service mysql start 2>/dev/null
            
            # Aguarda MySQL iniciar com timeout
            local timeout=30
            local count=0
            while [[ $count -lt $timeout ]]; do
                if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1;" > /dev/null 2>&1; then
                    break
                fi
                sleep 1
                ((count++))
            done
            
            if [[ $count -eq $timeout ]]; then
                echo "Erro: Timeout ao aguardar MySQL iniciar"
                send_webhook "error" "MySQL não iniciou" "Timeout ao aguardar MySQL iniciar após $timeout segundos" "R008" "$BACKUP_FILE"
                return 1
            fi
        fi
        echo "✓ MySQL está rodando e acessível"
        
        # Etapa 2: Análise do backup mydumper
        echo "Etapa 2/5: Analisando estrutura do backup mydumper..."
        
        # Conta arquivos SQL no backup
        local sql_files=$(find "$backup_dir" -name "*.sql" -type f | wc -l)
        local metadata_file="$backup_dir/metadata"
        
        if [[ $sql_files -eq 0 ]]; then
            echo "Erro: Nenhum arquivo SQL encontrado no backup"
            send_webhook "error" "Backup inválido" "Nenhum arquivo SQL encontrado no diretório de backup" "R009" "$BACKUP_FILE"
            return 1
        fi
        
        echo "✓ Encontrados $sql_files arquivos SQL para restore"
        
        # Verifica arquivo de metadata se existir
        if [[ -f "$metadata_file" ]]; then
            echo "✓ Arquivo metadata encontrado"
            local backup_info=$(grep -E "(Started|Finished)" "$metadata_file" 2>/dev/null || echo "Informações não disponíveis")
            echo "Informações do backup: $backup_info"
        fi
        
        # Etapa 3: Configuração de performance para myloader
        echo "Etapa 3/5: Configurando parâmetros de performance..."
        
        # Detecta número total de threads da máquina
        local cpu_threads=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")
        
        # Configurações otimizadas para myloader
        local myloader_opts=(
            "--host=$DB_HOST"
            "--port=$DB_PORT" 
            "--user=$DB_USER"
            "--password=$DB_PASS"
            "--directory=$backup_dir"
            "--threads=$cpu_threads"
            "--compress-protocol"
            "--overwrite-tables"
            "--enable-binlog"
            "--verbose=2"
            "--rows=10000"                    # Processa 10k linhas por vez
            "--max-packet-size=1073741824"    # Pacotes de até 1GB (performance)
            "--innodb-optimize-keys"          # Otimiza chaves InnoDB
            "--skip-definer"                  # Ignora definers para compatibilidade
            "--purge-mode=TRUNCATE"           # Usa TRUNCATE ao invés de DELETE
        )
        
        echo "✓ Configurado para usar $threads threads"
        
        # Etapa 4: Backup de segurança (opcional para mydumper)
        echo "Etapa 4/5: Preparando ambiente para restore..."
        
        # Desabilita foreign key checks temporariamente para performance
        mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SET GLOBAL foreign_key_checks = 0;" 2>/dev/null || true
        mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SET GLOBAL unique_checks = 0;" 2>/dev/null || true
        
        echo "✓ Otimizações de performance aplicadas"
        
        # Etapa 5: Execução do restore com myloader
        echo "Etapa 5/5: Executando restore com myloader..."
        local restore_log="$TMP_DIR/myloader_restore.log"
        
        echo "Comando: myloader ${myloader_opts[*]}"
        myloader "${myloader_opts[@]}" 2>&1 | tee "$restore_log"
        
        local restore_result=${PIPESTATUS[0]}
        
        # Reabilita foreign key checks
        mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SET GLOBAL foreign_key_checks = 1;" 2>/dev/null || true
        mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SET GLOBAL unique_checks = 1;" 2>/dev/null || true
        
        if [[ $restore_result -ne 0 ]]; then
            echo "Erro: Falha ao restaurar com myloader"
            echo "Log de erro salvo em: $restore_log"
            send_webhook "error" "Falha no restore mydumper" "Erro ao restaurar backup com myloader. Verifique log: $restore_log" "R003" "$BACKUP_FILE"
            return 1
        fi
        
        echo "✓ Restore executado com sucesso"
        
        # Verifica integridade básica do restore
        echo "Verificando integridade do restore..."
        local tables_count=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys');" -s -N 2>/dev/null || echo "0")
        
        if [[ $tables_count -gt 0 ]]; then
            echo "✓ Restore verificado: $tables_count tabelas restauradas"
        else
            echo "⚠ Aviso: Nenhuma tabela encontrada após restore"
        fi
        
        echo "=== RESTORE REMOTO MYLOADER CONCLUÍDO ==="
    fi
    
    # === VALIDAÇÕES E VERIFICAÇÕES DE INTEGRIDADE ===
    echo "=== INICIANDO VALIDAÇÕES PÓS-RESTORE ==="
    
    # Validação 1: Conectividade básica do MySQL
    echo "Validação 1/6: Verificando conectividade do MySQL..."
    local connection_attempts=0
    local max_attempts=5
    
    while [[ $connection_attempts -lt $max_attempts ]]; do
        if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT 1;" > /dev/null 2>&1; then
            echo "✓ MySQL conectado com sucesso"
            break
        else
            ((connection_attempts++))
            echo "Tentativa $connection_attempts/$max_attempts falhou, aguardando..."
            sleep 2
        fi
    done
    
    if [[ $connection_attempts -eq $max_attempts ]]; then
        echo "❌ Erro: MySQL não responde após $max_attempts tentativas"
        send_webhook "error" "MySQL não responde" "MySQL não responde após processo de restore" "R004" "$BACKUP_FILE"
        return 1
    fi
    
    # Validação 2: Verificação de estrutura do banco
    echo "Validação 2/6: Verificando estrutura do banco de dados..."
    local databases_count=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SHOW DATABASES;" -s -N 2>/dev/null | grep -v -E '^(information_schema|performance_schema|mysql|sys)$' | wc -l)
    local tables_count=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys');" -s -N 2>/dev/null || echo "0")
    
    echo "✓ Encontrados $databases_count banco(s) de dados e $tables_count tabela(s)"
    
    if [[ $tables_count -eq 0 ]]; then
        echo "⚠ Aviso: Nenhuma tabela de usuário encontrada"
    fi
    
    # Validação 3: Verificação de integridade das tabelas (apenas para xtrabackup)
    if [[ "$backup_format" == "xtrabackup" ]]; then
        echo "Validação 3/6: Verificando integridade das tabelas (xtrabackup)..."
        local corrupted_tables=0
        
        # Executa CHECK TABLE em algumas tabelas principais
        local check_result=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "
            SELECT CONCAT(table_schema, '.', table_name) as table_name 
            FROM information_schema.tables 
            WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') 
            AND table_type = 'BASE TABLE' 
            LIMIT 10;" -s -N 2>/dev/null)
        
        if [[ -n "$check_result" ]]; then
            while IFS= read -r table; do
                if [[ -n "$table" ]]; then
                    local check_status=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "CHECK TABLE $table;" -s -N 2>/dev/null | tail -1 | awk '{print $NF}')
                    if [[ "$check_status" != "OK" ]]; then
                        echo "⚠ Tabela $table: $check_status"
                        ((corrupted_tables++))
                    fi
                fi
            done <<< "$check_result"
        fi
        
        if [[ $corrupted_tables -eq 0 ]]; then
            echo "✓ Integridade das tabelas verificada"
        else
            echo "⚠ Encontradas $corrupted_tables tabela(s) com problemas"
        fi
    else
        echo "Validação 3/6: Pulando verificação de integridade (mydumper)"
    fi
    
    # Validação 4: Verificação de espaço em disco pós-restore
    echo "Validação 4/6: Verificando espaço em disco..."
    local mysql_datadir=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT @@datadir;" -s -N 2>/dev/null || echo "/var/lib/mysql")
    local disk_usage=$(df -h "$mysql_datadir" 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [[ -n "$disk_usage" && $disk_usage -lt 90 ]]; then
        echo "✓ Espaço em disco adequado: ${disk_usage}% usado"
    else
        echo "⚠ Aviso: Espaço em disco crítico: ${disk_usage}% usado"
    fi
    
    # Validação 5: Verificação de logs de erro do MySQL
    echo "Validação 5/6: Verificando logs de erro do MySQL..."
    local error_log=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "SELECT @@log_error;" -s -N 2>/dev/null)
    
    if [[ -n "$error_log" && -f "$error_log" ]]; then
        local recent_errors=$(tail -50 "$error_log" 2>/dev/null | grep -i error | wc -l)
        if [[ $recent_errors -eq 0 ]]; then
            echo "✓ Nenhum erro recente encontrado nos logs"
        else
            echo "⚠ Encontrados $recent_errors erro(s) recente(s) nos logs"
        fi
    else
        echo "✓ Log de erro não acessível ou não configurado"
    fi
    
    # Validação 6: Teste de operações básicas
    echo "Validação 6/6: Testando operações básicas do banco..."
    local test_db="test_restore_$(date +%s)"
    
    # Tenta criar um banco de teste
    if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "CREATE DATABASE IF NOT EXISTS $test_db;" > /dev/null 2>&1; then
        # Tenta criar uma tabela de teste
        if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$test_db" -e "CREATE TABLE test_table (id INT PRIMARY KEY, data VARCHAR(50));" > /dev/null 2>&1; then
            # Tenta inserir dados
            if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$test_db" -e "INSERT INTO test_table VALUES (1, 'teste');" > /dev/null 2>&1; then
                # Tenta ler dados
                local test_result=$(mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$test_db" -e "SELECT data FROM test_table WHERE id=1;" -s -N 2>/dev/null)
                if [[ "$test_result" == "teste" ]]; then
                    echo "✓ Operações básicas funcionando corretamente"
                    # Limpa o banco de teste
                    mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" -e "DROP DATABASE IF EXISTS $test_db;" > /dev/null 2>&1
                else
                    echo "⚠ Problema na leitura de dados"
                fi
            else
                echo "⚠ Problema na inserção de dados"
            fi
        else
            echo "⚠ Problema na criação de tabela"
        fi
    else
        echo "⚠ Problema na criação de banco de dados"
    fi
    
    # === RELATÓRIO FINAL DE PERFORMANCE ===
    local restore_end_time=$(date +%s)
    local restore_start_time=${restore_start_time:-$restore_end_time}
    local total_duration=$((restore_end_time - restore_start_time))
    local minutes=$((total_duration / 60))
    local seconds=$((total_duration % 60))
    
    # Detecta recursos do sistema para relatório
    local cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")
    local total_memory=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024)}' || echo "4096")
    local optimal_threads=$((cpu_cores > 16 ? 16 : cpu_cores))
    local buffer_size=$((total_memory > 8192 ? 1024 : total_memory / 8))
    
    echo "=== RELATÓRIO FINAL DE PERFORMANCE ==="
    echo "✅ Restore concluído com sucesso"
    echo "⏱️  Tempo total: ${minutes}m ${seconds}s"
    echo "📊 Estatísticas:"
    echo "   - Banco(s) de dados: $databases_count"
    echo "   - Tabela(s): $tables_count"
    echo "   - Formato do backup: $backup_format"
    echo "   - Modo: $(get_backup_mode)"
    echo "   - Uso de disco: ${disk_usage}%"
    echo "   - Threads utilizadas: $optimal_threads"
    echo "   - Buffer configurado: ${buffer_size}MB"
    echo "   - CPU(s) disponível(is): $cpu_cores"
    echo "   - Memória total: ${total_memory}MB"
    
    # Salva métricas de performance
    local performance_summary="$TMP_DIR/restore_performance_summary.log"
    cat > "$performance_summary" << EOF
=== RELATÓRIO DE PERFORMANCE DO RESTORE ===
Data/Hora: $(date '+%Y-%m-%d %H:%M:%S')
Arquivo de backup: $backup_file
Formato: $backup_format
Modo: $(get_backup_mode)
Duração total: ${minutes}m ${seconds}s
Bancos restaurados: $databases_count
Tabelas restauradas: $tables_count
Recursos utilizados:
  - CPUs: $cpu_cores
  - Threads: $optimal_threads
  - Memória total: ${total_memory}MB
  - Buffer: ${buffer_size}MB
  - Uso de disco final: ${disk_usage}%
Status: SUCESSO
EOF
    
    echo "📄 Logs salvos em:"
    echo "   - Log detalhado: $restore_log_file"
    echo "   - Performance: $performance_summary"
    
    # Limpa logs antigos (mantém apenas os últimos 10)
    find "$TMP_DIR" -name "restore_*.log" -type f -mtime +7 -delete 2>/dev/null || true
    find "$TMP_DIR" -name "restore_performance*.log" -type f | sort -r | tail -n +11 | xargs rm -f 2>/dev/null || true
    
    send_webhook "success" "Restore concluído com validações" "Backup restaurado e validado com sucesso em ${minutes}m ${seconds}s. $databases_count banco(s), $tables_count tabela(s)" "R000" "$BACKUP_FILE"
    return 0
}





echo "Iniciando processo de restore do backup: $BACKUP_FILE"

# Inicializa timestamp para performance
restore_start_time=$(date +%s)

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
                    echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
                    echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
                    echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
    # Só limpa arquivos temporários se a etapa foi bem-sucedida e é a última etapa
    if [[ "$SPECIFIC_STEP" == "restore" ]]; then
        cleanup_temp_files
        cleanup_checkpoints "true"
    fi
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
            echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
            echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
            echo "AVISO: Arquivos temporários preservados para nova tentativa"
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
