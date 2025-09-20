#!/bin/bash

source "$(dirname "$0")/../.env"

CUTOFF_DATE=$(date -d "-30 days" +%s)

aws s3 ls "s3://$S3_BUCKET/$R2_FOLDER/" --endpoint-url "$S3_ENDPOINT" | while read -r line; do
    FILE_DATE=$(echo $line | awk '{print $1, $2}')
    FILE_NAME=$(echo $line | awk '{print $4}')
    if [[ -z "$FILE_NAME" ]]; then continue; fi

    FILE_TIMESTAMP=$(date -d "$FILE_DATE" +%s)
    if (( FILE_TIMESTAMP < CUTOFF_DATE )); then
        aws s3 rm "s3://$S3_BUCKET/$R2_FOLDER/$FILE_NAME" --endpoint-url "$S3_ENDPOINT"
        if [[ "$WEBHOOK_EVENTS" == *"cleanup"* ]]; then
            curl -X POST -H "Content-Type: application/json" -d '{"event":"cleanup_deleted","file":"'"$FILE_NAME"'"}' "$WEBHOOK_URL"
        fi
    fi
done
