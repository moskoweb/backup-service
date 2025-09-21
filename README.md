# Sistema de Backup MySQL Híbrido para Cloudflare R2

Sistema inteligente de backup MySQL que suporta dois modos de operação: **local** (Percona XtraBackup) para backups físicos completos e **remoto** (mydumper) para backups lógicos flexíveis.

## 🎯 Características Principais

- **Backup Híbrido**: Escolha entre backup físico (XtraBackup) ou lógico (mydumper)
- **Detecção Automática**: Sistema detecta automaticamente o melhor método baseado na configuração
- **Backup Incremental Inteligente**: Suporte completo para backups incrementais no modo local
- **Armazenamento em Nuvem**: Upload direto para Cloudflare R2 (compatível com S3)
- **Webhooks**: Notificações em tempo real sobre status dos backups
- **Retenção Automática**: Limpeza automática de backups antigos
- **Configuração Flexível**: Diferentes configurações por ambiente

## 📦 Estrutura do Projeto

```
percona-backup-r2-package/
├── .env                    # Configurações gerais e exemplos
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
  - Backup incremental nativo
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
GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO 'backup_user'@'localhost';
GRANT CREATE, INSERT, DROP, UPDATE ON mysql.backup_progress TO 'backup_user'@'localhost';

-- Para modo remoto (mydumper) - adicionar também:
GRANT SELECT ON *.* TO 'backup_user'@'localhost';
GRANT SHOW VIEW ON *.* TO 'backup_user'@'localhost';
GRANT TRIGGER ON *.* TO 'backup_user'@'localhost';

FLUSH PRIVILEGES;
```

## ⚙️ Configuração

### 1. Configurar Variáveis de Ambiente
Edite o arquivo <mcfile name=".env" path="/Users/alanmosko/Sites/percona-backup-r2-package/.env"></mcfile> com suas configurações:

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

### Backup Automático
O sistema detecta automaticamente se deve fazer backup full ou incremental:

```bash
# Execução automática (recomendado)
./scripts/backup.sh
```

**Lógica Automática:**
- **Domingo**: Sempre backup full
- **Segunda a Sábado**: 
  - Modo local: backup incremental
  - Modo remoto: backup full (mydumper não suporta incremental)

### Backup Explícito
```bash
# Forçar backup full
./scripts/backup.sh full

# Forçar backup incremental (apenas modo local)
./scripts/backup.sh incremental
```

### Restauração
```bash
# Restaurar backup específico
./scripts/restore.sh 2025-01-20-full.tar.gz

# Listar backups disponíveis
./scripts/restore.sh --list
```

### Limpeza de Backups Antigos
```bash
# Executar limpeza baseada na retenção configurada
./scripts/cleanup.sh

# Limpeza com retenção específica (em dias)
./scripts/cleanup.sh 15
```

## 🔔 Webhooks e Notificações

Configure webhooks para receber notificações em tempo real:

```bash
# No .env
WEBHOOK_URL=https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
WEBHOOK_EVENTS=success,error,restore,cleanup
```

**Eventos Disponíveis:**
- `success`: Backup concluído com sucesso
- `error`: Erro durante o backup
- `restore`: Restauração realizada
- `cleanup`: Limpeza de backups executada

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

#### Backup Incremental Não Funciona
- Verifique se está usando `BACKUP_MODE=local`
- Confirme que existe um backup full anterior
- Verifique logs para erros do XtraBackup

### Logs e Debug
```bash
# Habilitar modo debug
export DEBUG=1
./scripts/backup.sh

# Verificar logs detalhados
tail -f /tmp/backup_debug.log
```

## 📊 Comparação de Performance

| Aspecto | Modo Local (XtraBackup) | Modo Remoto (mydumper) |
|---------|-------------------------|------------------------|
| **Velocidade Backup** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Velocidade Restore** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **Backup Incremental** | ✅ Nativo | ❌ Não suportado |
| **Paralelização** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Compressão** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Flexibilidade** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Compatibilidade** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

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