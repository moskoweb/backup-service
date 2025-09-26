# Sistema de Backup MySQL Híbrido para Cloudflare R2

Sistema inteligente de backup MySQL que suporta dois modos de operação: **local** (Percona XtraBackup) para backups físicos completos e **remoto** (mydumper) para backups lógicos flexíveis.

## 🎯 Características Principais

- **Backup Híbrido**: Escolha entre backup físico (XtraBackup) ou lógico (mydumper)
- **Detecção Automática**: Sistema detecta automaticamente o melhor método baseado na configuração
- **Backup Completo**: Backups completos confiáveis em ambos os modos
- **Armazenamento em Nuvem**: Upload direto para Cloudflare R2 (compatível com S3)
- **Sistema Modular**: Execução por etapas independentes com checkpoints automáticos
- **Checkpoints Inteligentes**: Retomada automática de processos interrompidos
- **Execução Granular**: Execute etapas específicas ou processo completo
- **Webhooks**: Notificações em tempo real sobre status dos backups
- **Retenção Automática**: Limpeza automática de backups antigos
- **Configuração Flexível**: Diferentes configurações por ambiente
- **Alta Confiabilidade**: Validações robustas e recuperação automática de falhas

## 📦 Estrutura do Projeto

```
percona-backup-r2-package/
├── .env.example           # Configurações gerais e exemplos
├── scripts/
│   ├── backup.sh          # Script principal de backup
│   ├── restore.sh         # Script de restauração
│   └── cleanup.sh         # Script de limpeza/retenção
└── README.md              # Esta documentação
```

## 🔄 Modos de Backup

### 🏠 Modo Local (BACKUP_MODE=local)
- **Ferramenta**: Percona XtraBackup
- **Tipo**: Backup físico (arquivos de dados)
- **Vantagens**: 
  - Backup físico completo
  - Restauração mais rápida
  - Menor impacto no servidor durante backup
- **Ideal para**: Servidores de produção, backups regulares

### 🌐 Modo Remoto (BACKUP_MODE=remote)
- **Ferramenta**: mydumper/myloader
- **Tipo**: Backup lógico (SQL dumps)
- **Vantagens**:
  - Backup paralelo e compressão
  - Compatibilidade entre versões MySQL
  - Backup seletivo de tabelas
- **Ideal para**: Análises, migrações, ambientes de desenvolvimento

## ⚡ Sistema Modular e Checkpoints

### 🔄 Execução Modular
Todos os scripts principais (`backup.sh`, `restore.sh`, `cleanup.sh`) agora suportam execução modular por etapas:

#### 📦 Backup Modular
```bash
# Processo completo (padrão)
./scripts/backup.sh

# Etapas específicas
./scripts/backup.sh --step backup      # Apenas backup do banco
./scripts/backup.sh --step compression # Apenas compressão
./scripts/backup.sh --step upload      # Apenas upload para R2

# Para backup completo
./scripts/backup.sh full # Backup completo
```

#### 🔄 Restore Modular
```bash
# Processo completo (padrão)
./scripts/restore.sh backup-file.tar.gz

# Etapas específicas
./scripts/restore.sh backup-file.tar.gz --step download  # Apenas download
./scripts/restore.sh backup-file.tar.gz --step extract  # Apenas extração
./scripts/restore.sh backup-file.tar.gz --step restore  # Apenas restore
```

#### 🧹 Cleanup Modular
```bash
# Processo completo (padrão)
./scripts/cleanup.sh

# Etapas específicas
./scripts/cleanup.sh --step list    # Apenas listagem de arquivos
./scripts/cleanup.sh --step delete  # Apenas remoção de arquivos antigos
./scripts/cleanup.sh --step verify  # Apenas verificação final
```

### 🎯 Sistema de Checkpoints

#### Como Funciona
- **Checkpoints Diários**: Cada etapa é salva como checkpoint por dia
- **Retomada Automática**: Etapas já concluídas são automaticamente puladas
- **Validação Inteligente**: Verifica integridade antes de pular etapas
- **Limpeza Automática**: Checkpoints antigos são removidos automaticamente

#### Benefícios
- **Eficiência**: Evita reexecução desnecessária de etapas
- **Confiabilidade**: Permite retomar processos interrompidos
- **Flexibilidade**: Execute apenas as etapas necessárias
- **Debugging**: Facilita identificação de problemas específicos

#### Exemplo Prático
```bash
# Dia 1: Processo interrompido na etapa de upload
./scripts/backup.sh
# ✓ Backup concluído
# ✓ Compressão concluída  
# ✗ Upload falhou (conexão perdida)

# Dia 1: Reexecução - apenas upload será executado
./scripts/backup.sh
# ✓ Backup já concluído, pulando...
# ✓ Compressão já concluída, pulando...
# ⚡ Executando upload...
# ✓ Upload concluído
```

### 📋 Ajuda e Documentação
Todos os scripts incluem ajuda integrada:

```bash
./scripts/backup.sh --help
./scripts/restore.sh --help
./scripts/cleanup.sh --help
```

## 🔧 Instalação

### Requisitos do Sistema

**Compatibilidade**: Linux (Ubuntu/Debian/CentOS) e macOS

#### Linux (Ubuntu/Debian)
```bash
# Atualizar sistema
sudo apt update

# Para Modo Local (XtraBackup)
wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
sudo dpkg -i percona-release_latest.generic_all.deb
sudo percona-release setup ps80
sudo apt update
sudo apt install percona-xtrabackup-80 -y

# Para Modo Remoto (mydumper)
sudo apt install mydumper -y

# AWS CLI (para ambos os modos)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

#### macOS
```bash
# Instalar Homebrew (se não tiver)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Para Modo Local (XtraBackup)
brew install percona-xtrabackup

# Para Modo Remoto (mydumper)
brew install mydumper

# AWS CLI (para ambos os modos)
brew install awscli
```

### Configuração do MySQL
Crie um usuário específico para backups:

```sql
-- Para modo local (XtraBackup)
CREATE USER 'backup_user'@'localhost' IDENTIFIED BY 'senha_segura';
GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT, BACKUP_ADMIN ON *.* TO 'backup_user'@'localhost';
GRANT CREATE, INSERT, DROP, UPDATE ON mysql.backup_progress TO 'backup_user'@'localhost';

-- Para modo remoto (mydumper) - adicionar também:
GRANT SELECT ON *.* TO 'backup_user'@'localhost';
GRANT SHOW VIEW ON *.* TO 'backup_user'@'localhost';
GRANT TRIGGER ON *.* TO 'backup_user'@'localhost';

FLUSH PRIVILEGES;
```

## ⚙️ Configuração

### 1. Configurar Variáveis de Ambiente
Copie o arquivo de exemplo para o arquivo de configuração:

```bash
cp .env.example .env
```

Edite o arquivo `.env` com suas configurações:

```bash
# Modo de backup (local ou remote)
BACKUP_MODE=local

# Configurações do banco
DB_HOST=localhost
DB_PORT=3306
DB_USER=backup_user
DB_PASSWORD=senha_segura
DB_NAME=meu_banco

# Configurações do Cloudflare R2
R2_ENDPOINT=https://account-id.r2.cloudflarestorage.com
R2_BUCKET=meu-bucket-backup
AWS_ACCESS_KEY_ID=sua_access_key
AWS_SECRET_ACCESS_KEY=sua_secret_key

# Configurações opcionais
RETENTION_DAYS=30
WEBHOOK_URL=https://hooks.slack.com/services/...
WEBHOOK_EVENTS=success,error
```

### 2. Exemplos de Configuração por Ambiente

#### Produção (Backup Físico)
```bash
BACKUP_MODE=local
DB_HOST=prod-mysql.empresa.com
DB_NAME=producao_db
RETENTION_DAYS=90
WEBHOOK_EVENTS=success,error,cleanup
```

#### Desenvolvimento (Backup Lógico)
```bash
BACKUP_MODE=remote
DB_HOST=dev-mysql.empresa.com
DB_NAME=desenvolvimento_db
RETENTION_DAYS=7
```

#### Análise de Dados (Backup Seletivo)
```bash
BACKUP_MODE=remote
DB_HOST=analytics-mysql.empresa.com
DB_NAME=analytics_db
```

## 🚀 Uso

### Backup Completo
O sistema executa sempre backup completo:

```bash
# Execução padrão (recomendado)
./scripts/backup.sh

# Ou explicitamente
./scripts/backup.sh full

# Executar apenas etapas específicas
./scripts/backup.sh --step backup      # Só backup
./scripts/backup.sh --step compression # Só compressão
./scripts/backup.sh --step upload      # Só upload
```

### Restauração
```bash
# Restaurar backup específico
./scripts/restore.sh 2025-01-20-full.tar.gz

# Listar backups disponíveis
./scripts/restore.sh --list

# Execução modular - etapas específicas
./scripts/restore.sh backup.tar.gz --step download  # Só download
./scripts/restore.sh backup.tar.gz --step extract  # Só extração
./scripts/restore.sh backup.tar.gz --step restore  # Só restore

# Ver opções disponíveis
./scripts/restore.sh --help
```

### Limpeza de Backups Antigos
```bash
# Executar limpeza baseada na retenção configurada
./scripts/cleanup.sh

# Limpeza com retenção específica (em dias)
./scripts/cleanup.sh 15

# Execução modular - etapas específicas
./scripts/cleanup.sh --step list    # Só listagem
./scripts/cleanup.sh --step delete  # Só remoção
./scripts/cleanup.sh --step verify  # Só verificação

# Ver opções disponíveis
./scripts/cleanup.sh --help
```

### 🔄 Recursos Avançados

#### Retomada Automática
```bash
# Se um processo foi interrompido, simplesmente execute novamente
# O sistema automaticamente detecta e retoma de onde parou
./scripts/backup.sh   # Retoma automaticamente
./scripts/restore.sh backup.tar.gz  # Retoma automaticamente
./scripts/cleanup.sh  # Retoma automaticamente
```

#### Debugging e Monitoramento
```bash
# Verificar status de checkpoints
ls -la /tmp/backup_checkpoints_$(date +%Y%m%d)/

# Forçar limpeza de checkpoints (se necessário)
rm -rf /tmp/backup_checkpoints_*
rm -rf /tmp/restore_checkpoints_*
rm -rf /tmp/cleanup_checkpoints_*
```

## 🔔 Webhooks e Notificações

Configure webhooks para receber notificações em tempo real sobre todas as operações do sistema:

```bash
# No .env
WEBHOOK_URL=https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
WEBHOOK_EVENTS=success,error,restore,cleanup
```

### 🏷️ Códigos de Status Padronizados

O sistema utiliza códigos padronizados para identificar diferentes tipos de eventos:

#### 📦 **Backup (backup.sh)**
- **B000**: Backup concluído com sucesso
- **B001**: Falha no backup do banco de dados
- **B002**: Falha na compactação do backup
- **B003**: Falha no upload para R2

#### 🔄 **Restore (restore.sh)**
- **R000**: Restore concluído com sucesso
- **R001**: Falha no download do backup
- **R002**: Falha na extração do backup
- **R003**: Falha no restore do backup

#### 🧹 **Cleanup (cleanup.sh)**
- **C000**: Processo de limpeza concluído
- **C001**: Falha na listagem de arquivos
- **C002**: Falha na remoção de arquivos
- **C003**: Falha na verificação final

### 📋 Lista Completa de Webhooks Ativos

#### 📦 **Script de Backup (backup.sh)**

**Webhooks de Sucesso:**
- **B000** - `"Backup concluído com sucesso"` - Backup finalizado com sucesso

**Webhooks de Erro:**
- **B001** - `"Falha no backup do banco de dados"` - Erro durante execução do backup
- **B002** - `"Falha na compactação do backup"` - Erro durante compactação do arquivo
- **B003** - `"Falha no upload para R2"` - Erro ao enviar arquivo para o bucket

#### 🔄 **Script de Restore (restore.sh)**

**Webhooks de Sucesso:**
- **R000** - `"Restore concluído"` - Restore do backup concluído com sucesso

**Webhooks de Erro:**
- **R001** - `"Falha no download do backup"` - Erro ao baixar arquivo do bucket
- **R002** - `"Falha na extração do backup"` - Erro ao extrair arquivo de backup
- **R003** - `"Falha no restore do backup"` - Erro ao restaurar dados do MySQL

#### 🧹 **Script de Limpeza (cleanup.sh)**

**Webhooks de Sucesso:**
- **C000** - `"Processo de limpeza concluído"` - Limpeza completa finalizada com sucesso

**Webhooks de Erro:**
- **C001** - `"Falha na listagem de arquivos"` - Erro durante listagem de arquivos
- **C002** - `"Falha na remoção de arquivos"` - Erro durante remoção de arquivos antigos
- **C003** - `"Falha na verificação final"` - Erro durante verificação final de limpeza

### 📊 **Exemplos de Webhooks Enviados**

#### ✅ **Webhook de Sucesso (Backup)**
```json
{
    "event": "success",
    "timestamp": "2025-01-21 02:00:00",
    "message": "Backup concluído com sucesso",
    "code": "B000",
    "details": "Backup full finalizado",
    "filename": "backup_20250121_020000.tar.gz"
}
```

#### ❌ **Webhook de Erro (Restore)**
```json
{
    "event": "error",
    "timestamp": "2025-01-21 03:15:00",
    "message": "Falha no download do backup",
    "code": "R001",
    "details": "Erro ao baixar arquivo do bucket",
    "filename": "backup_20250120_020000.tar.gz"
}
```

#### ✅ **Webhook de Sucesso (Cleanup)**
```json
{
    "event": "success",
    "timestamp": "2025-01-21 04:00:00",
    "message": "Processo de limpeza concluído",
    "code": "C000",
    "details": "Limpeza completa finalizada com sucesso",
    "removed_files": 5,
    "freed_space": "2.3GB"
}
```


## 🗓️ Agendamento com Cron

### Configuração Recomendada
```bash
# Editar crontab
crontab -e

# Backup diário às 2h da manhã
0 2 * * * /caminho/para/scripts/backup.sh >> /var/log/mysql-backup.log 2>&1

# Limpeza semanal aos domingos às 3h
0 3 * * 0 /caminho/para/scripts/cleanup.sh >> /var/log/mysql-cleanup.log 2>&1
```

### Configuração Avançada por Ambiente
```bash
# Produção: backup diário + limpeza semanal
0 2 * * * /opt/backup/scripts/backup.sh
0 3 * * 0 /opt/backup/scripts/cleanup.sh

# Desenvolvimento: backup a cada 6 horas
0 */6 * * * /opt/backup/scripts/backup.sh

# Staging: backup diário + retenção menor
0 1 * * * /opt/backup/scripts/backup.sh
0 2 * * 0 /opt/backup/scripts/cleanup.sh 7
```

## 🔍 Monitoramento e Logs

### Verificar Status dos Backups
```bash
# Ver logs do último backup
tail -f /var/log/mysql-backup.log

# Verificar backups no R2
aws s3 ls s3://seu-bucket-backup/ --endpoint-url=https://account-id.r2.cloudflarestorage.com
```

### Métricas Importantes
- **Tempo de execução**: Monitore a duração dos backups
- **Tamanho dos arquivos**: Acompanhe o crescimento dos backups
- **Taxa de sucesso**: Verifique falhas através dos webhooks
- **Espaço em disco**: Monitore o diretório temporário

## 🛠️ Solução de Problemas

### Problemas Comuns

#### Erro de Permissões MySQL
```bash
# Verificar permissões do usuário
SHOW GRANTS FOR 'backup_user'@'localhost';

# Recriar usuário se necessário
DROP USER 'backup_user'@'localhost';
# ... recriar com permissões corretas
```

#### Falha no Upload para R2
```bash
# Testar conectividade
aws s3 ls s3://seu-bucket/ --endpoint-url=https://account-id.r2.cloudflarestorage.com

# Verificar credenciais
aws configure list
```


#### Problemas com Checkpoints
```bash
# Checkpoint corrompido ou inválido
rm -rf /tmp/backup_checkpoints_$(date +%Y%m%d)
./scripts/backup.sh  # Reinicia processo completo

# Verificar integridade dos checkpoints
ls -la /tmp/backup_checkpoints_$(date +%Y%m%d)/
cat /tmp/backup_checkpoints_$(date +%Y%m%d)/backup_completed

# Forçar execução de etapa específica (ignora checkpoint)
rm /tmp/backup_checkpoints_$(date +%Y%m%d)/upload_completed
./scripts/backup.sh --step upload
```

#### Processo Travado em Etapa Específica
```bash
# Identificar qual etapa está travada
./scripts/backup.sh --help  # Ver etapas disponíveis

# Executar etapa específica para debug
./scripts/backup.sh --step backup
./scripts/backup.sh --step compression
./scripts/backup.sh --step upload

# Para restore
./scripts/restore.sh backup.tar.gz --step download
./scripts/restore.sh backup.tar.gz --step extract
./scripts/restore.sh backup.tar.gz --step restore
```

#### Falha na Validação de Arquivos
```bash
# Verificar integridade manualmente
tar -tzf /tmp/backup.tar.gz > /dev/null && echo "Arquivo OK" || echo "Arquivo corrompido"

# Recriar arquivo se necessário
rm /tmp/backup_checkpoints_$(date +%Y%m%d)/compression_completed
./scripts/backup.sh --step compression
```

### Logs e Debug
```bash
# Habilitar modo debug
export DEBUG=1
./scripts/backup.sh

# Verificar logs detalhados
tail -f /tmp/backup_debug.log

# Logs específicos por etapa
tail -f /tmp/backup_backup.log
tail -f /tmp/backup_compression.log
tail -f /tmp/backup_upload.log

# Verificar status de checkpoints
find /tmp -name "*_checkpoints_*" -type d
ls -la /tmp/backup_checkpoints_$(date +%Y%m%d)/
```

### 🔧 Comandos de Manutenção

#### Limpeza de Checkpoints Antigos
```bash
# Limpeza automática (executada pelos scripts)
find /tmp -name "*_checkpoints_*" -type d -mtime +7 -exec rm -rf {} \;

# Limpeza manual de todos os checkpoints
rm -rf /tmp/backup_checkpoints_*
rm -rf /tmp/restore_checkpoints_*
rm -rf /tmp/cleanup_checkpoints_*
```

#### Reset Completo do Sistema
```bash
# Para reiniciar completamente todos os processos
rm -rf /tmp/backup_checkpoints_*
rm -rf /tmp/restore_checkpoints_*
rm -rf /tmp/cleanup_checkpoints_*
rm -f /tmp/backup*.log
rm -f /tmp/restore*.log
rm -f /tmp/cleanup*.log

echo "Sistema resetado - próxima execução será completa"
```

## 📊 Comparação de Performance

| Aspecto | Modo Local (XtraBackup) | Modo Remoto (mydumper) | Sistema Modular |
|---------|-------------------------|------------------------|-----------------|
| **Velocidade Backup** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Velocidade Restore** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

| **Paralelização** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Compressão** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Flexibilidade** | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Compatibilidade** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Confiabilidade** | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Retomada Automática** | ❌ Não suportado | ❌ Não suportado | ✅ Checkpoints |
| **Execução Granular** | ❌ Processo único | ❌ Processo único | ✅ Por etapas |
| **Debugging** | ⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ |

### 🚀 Vantagens do Sistema Modular

#### ✅ Benefícios Operacionais
- **Retomada Inteligente**: Nunca perca progresso por falhas de rede ou sistema
- **Execução Seletiva**: Execute apenas as etapas necessárias
- **Debugging Facilitado**: Identifique problemas em etapas específicas
- **Eficiência de Recursos**: Evite reprocessamento desnecessário

#### ⚡ Cenários de Uso Otimizados
- **Conexões Instáveis**: Checkpoints garantem continuidade
- **Ambientes de Produção**: Menor impacto com execução granular
- **Manutenção**: Facilita troubleshooting e correções
- **Automação**: Integração perfeita com sistemas de monitoramento

## 🔒 Segurança

### Boas Práticas
1. **Credenciais**: Use variáveis de ambiente, nunca hardcode senhas
2. **Usuário MySQL**: Crie usuário específico com permissões mínimas
3. **Criptografia**: Backups são comprimidos e podem ser criptografados
4. **Acesso R2**: Use IAM policies restritivas no Cloudflare
5. **Logs**: Não registre senhas nos logs de sistema

### Exemplo de Política IAM para R2
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::seu-bucket-backup",
        "arn:aws:s3:::seu-bucket-backup/*"
      ]
    }
  ]
}
```

## 🤝 Contribuição

Para contribuir com o projeto:

1. Fork o repositório
2. Crie uma branch para sua feature (`git checkout -b feature/nova-funcionalidade`)
3. Commit suas mudanças (`git commit -am 'Adiciona nova funcionalidade'`)
4. Push para a branch (`git push origin feature/nova-funcionalidade`)
5. Abra um Pull Request

## 📝 Licença

Este projeto está sob a licença MIT. Veja o arquivo `LICENSE` para mais detalhes.

## 🆘 Suporte

Para suporte e dúvidas:
- Abra uma issue no GitHub
- Consulte a documentação do [Percona XtraBackup](https://docs.percona.com/percona-xtrabackup/)
- Consulte a documentação do [mydumper](https://github.com/mydumper/mydumper)
- Documentação do [Cloudflare R2](https://developers.cloudflare.com/r2/)