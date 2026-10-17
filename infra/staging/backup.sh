#!/bin/sh
# Daily PostgreSQL dump of the staging stack, kept for KEEP_DAYS days. Run from cron, e.g.
#   17 3 * * * /home/deploy/pillpal/backup.sh >> /home/deploy/pillpal/backups/backup.log 2>&1
# Restore: gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U pillpal -d pillpal
set -eu
cd "$(dirname "$0")"
KEEP_DAYS="${KEEP_DAYS:-14}"
mkdir -p backups
umask 077
file="backups/pillpal-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$file.tmp"
mv "$file.tmp" "$file"
find backups -name 'pillpal-*.sql.gz' -mtime "+$KEEP_DAYS" -delete
echo "backup written: $file"
