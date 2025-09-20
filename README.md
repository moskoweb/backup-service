# MySQL Backup para Cloudflare R2 com Percona XtraBackup

## 📦 Estrutura
- `.env`: configurações gerais
- `scripts/backup.sh`: realiza o backup (full ou incremental)
- `scripts/restore.sh`: restaura um backup
- `scripts/cleanup.sh`: limpa backups antigos (retenção)

## 🔧 Instalação
### Requisitos
```bash
sudo apt update
wget https://repo.percona.com/apt/percona-release_latest.generic_all.deb
sudo dpkg -i percona-release_latest.generic_all.deb
sudo percona-release setup ps80
sudo apt update
sudo apt install percona-xtrabackup-80 awscli -y
```

## ⚙️ Configuração
1. Edite o `.env` com os dados do banco e do Cloudflare R2.
2. Crie um usuário com permissões para backup no MySQL.

## 🚀 Uso
### Backup (automático: full no domingo, incremental nos demais)
```bash
./scripts/backup.sh
```

### Backup explícito:
```bash
./scripts/backup.sh full
./scripts/backup.sh incremental
```

### Restauração
```bash
./scripts/restore.sh 2025-09-20-full.tar.gz
```

### Limpeza (retenção de 30 dias)
```bash
./scripts/cleanup.sh
```

## 🔔 Webhooks
Configure `WEBHOOK_URL` e `WEBHOOK_EVENTS` no `.env` para receber eventos de:
- `success`, `error`, `restore`, `cleanup`

## 🗓️ Agendamento (Cron)
```bash
# Backup diário às 2h
0 2 * * * /caminho/para/scripts/backup.sh >> /var/log/backup.log 2>&1

# Cleanup semanal
0 3 * * 0 /caminho/para/scripts/cleanup.sh >> /var/log/cleanup.log 2>&1
```