# 🔐 Percona Backup & Restore System for Cloudflare R2 (S3-Compatible)

## 📁 Estrutura

- `.env`: Definições das variáveis de ambiente (credenciais, pasta, webhook etc)
- `scripts/backup.sh`: Faz o backup (full ou incremental)
- `scripts/restore.sh`: Restaura um backup informado
- `scripts/cleanup_old_backups.sh`: Limpa backups antigos do R2

## 🚀 Como Usar

### 1. Configurar `.env`

Copie o modelo `.env` e preencha com seus dados:

```bash
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
S3_BUCKET=...
R2_FOLDER=DB-Backup
DB_USER=...
DB_PASSWORD=...
WEBHOOK_URL=https://...
WEBHOOK_EVENTS=success,error,restore,cleanup
```

### 2. Executar backup manualmente

```bash
./scripts/backup.sh full         # ou incremental
```

Ou deixe o script decidir:

```bash
./scripts/backup.sh              # full aos domingos, incremental nos outros dias
```

### 3. Restaurar backup

```bash
./scripts/restore.sh 2025-09-20-full.tar.gz
```

### 4. Limpar backups antigos

```bash
./scripts/cleanup_old_backups.sh
```

## ⏱️ Agendamentos

Use `crontab -e`:

```bash
# Backup diário às 01h
0 1 * * * /caminho/scripts/backup.sh >> /var/log/db-backup.log 2>&1

# Limpeza semanal (domingo às 03h)
0 3 * * 0 /caminho/scripts/cleanup_old_backups.sh >> /var/log/db-cleanup.log 2>&1
```

---

Backups organizados, restauráveis e automatizados via webhook. Seguro, portátil e sem depender de disco local!

