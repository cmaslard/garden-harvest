#!/bin/sh
set -eu

STATE_FILE=/app/state/last_check
DB_URL="postgresql://postgres:${POSTGRES_PASSWORD}@db:${POSTGRES_PORT}/${POSTGRES_DB}"

if [ ! -f "$STATE_FILE" ]; then
  date -u +"%Y-%m-%d %H:%M:%S" > "$STATE_FILE"
  exit 0
fi
SINCE=$(cat "$STATE_FILE")

NEW=$(psql "$DB_URL" -Atc "SELECT email || ' (' || created_at || ')' FROM auth.users WHERE created_at > '${SINCE}' ORDER BY created_at")

if [ -n "$NEW" ]; then
  {
    printf 'Subject: Garden Harvest : nouvelle inscription\n'
    printf 'From: %s\n' "${SMTP_USER}"
    printf 'To: %s\n' "${ADMIN_EMAIL}"
    printf '\n'
    printf 'Nouveau(x) compte(s) cree(s) sur Garden Harvest :\n\n'
    echo "$NEW" | sed 's/^/ - /'
  } > /tmp/mail.txt
  curl --silent --show-error --ssl-reqd \
    --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
    --mail-from "${SMTP_USER}" \
    --mail-rcpt "${ADMIN_EMAIL}" \
    --upload-file /tmp/mail.txt \
    --user "${SMTP_USER}:${SMTP_PASS}"
fi

date -u +"%Y-%m-%d %H:%M:%S" > "$STATE_FILE"
