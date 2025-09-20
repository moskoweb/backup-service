#!/bin/bash

# Load environment variables
source "$(dirname "$0")/../.env"

# Set default backup type
BACKUP_TYPE=$1
if [[ -z "$BACKUP_TYPE" ]]; then
    DAY_OF_WEEK=$(date +%u)
    if [[ "$DAY_OF_WEEK" -eq 7 ]]; then
        BACKUP_TYPE="full"
    else
        BACKUP_TYPE="incremental"
    fi
fi

DATE=$(date +%F)
TMP_DIR="/tmp/db-backup-$DATE"
mkdir -p "$TMP_DIR"

# Define backup destination
FILENAME="${DATE}-${BACKUP_TYPE}.tar.gz"
ARCHIVE_PATH="/tmp/$FILENAME"

# Perform backup using Percona XtraBackup
if [[ "$BACKUP_TYPE" == "full" ]]; then
    innobackupex --user=$DB_USER --password=$DB_PASSWORD --host=$DB_HOST --port=$DB_PORT "$TMP_DIR"
else
    LATEST_FULL=$(aws s3 ls s3://$S3_BUCKET/$R2_FOLDER/ --endpoint-url $S3_ENDPOINT | grep full | sort | tail -n 1 | awk '{print $4}')
    if [[ -z "$LATEST_FULL" ]]; then
        echo "No full backup found. Aborting incremental."
        exit 1
    fi
    aws s3 cp "s3://$S3_BUCKET/$R2_FOLDER/$LATEST_FULL" "$TMP_DIR" --endpoint-url "$S3_ENDPOINT"
    tar -xzf "$TMP_DIR/$LATEST_FULL" -C "$TMP_DIR"
    innobackupex --user=$DB_USER --password=$DB_PASSWORD --host=$DB_HOST --port=$DB_PORT --incremental "$TMP_DIR" --incremental-basedir="$TMP_DIR"
fi

# Create archive
tar -czf "$ARCHIVE_PATH" -C "$TMP_DIR" .

# Upload to R2
aws s3 cp "$ARCHIVE_PATH" "s3://$S3_BUCKET/$R2_FOLDER/$FILENAME" --endpoint-url "$S3_ENDPOINT"

# Send webhook
if [[ "$WEBHOOK_EVENTS" == *"success"* ]]; then
    curl -X POST -H "Content-Type: application/json" -d '{"event":"backup_success","file":"'"$FILENAME"'"}' "$WEBHOOK_URL"
fi

# Cleanup
rm -rf "$TMP_DIR" "$ARCHIVE_PATH"
