#!/bin/bash

source "$(dirname "$0")/../.env"

BACKUP_FILE=$1
if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <backup_file.tar.gz>"
    exit 1
fi

TMP_DIR="/tmp/db-restore"
mkdir -p "$TMP_DIR"

# Download and extract
aws s3 cp "s3://$S3_BUCKET/$R2_FOLDER/$BACKUP_FILE" "$TMP_DIR" --endpoint-url "$S3_ENDPOINT"
tar -xzf "$TMP_DIR/$BACKUP_FILE" -C "$TMP_DIR"

# Restore
innobackupex --apply-log "$TMP_DIR"
innobackupex --copy-back "$TMP_DIR" --user=$DB_USER --password=$DB_PASSWORD --host=$DB_HOST --port=$DB_PORT

# Webhook
if [[ "$WEBHOOK_EVENTS" == *"restore"* ]]; then
    curl -X POST -H "Content-Type: application/json" -d '{"event":"restore_success","file":"'"$BACKUP_FILE"'"}' "$WEBHOOK_URL"
fi

rm -rf "$TMP_DIR"
