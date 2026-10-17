#!/usr/bin/env bash
# Daily PostgreSQL dump of the staging stack, kept for KEEP_DAYS days (default 14). Run from cron:
#   17 3 * * * /home/deploy/pillpal/backup.sh >> /home/deploy/pillpal/backups/backup.log 2>&1
# Restore: gunzip -c backups/<file>.sql.gz | docker compose exec -T postgres psql -U pillpal -d pillpal
#
# Privacy: a dump still holds accounts that were erased after it was taken. Account deletion has a
# 30-day grace and the erase job runs hourly; a backup older than KEEP_DAYS must not exist, so keep
# KEEP_DAYS <= 14 (docs/staging.md, docs/phase3-plan.md legal review).
set -euo pipefail
cd "$(dirname "$0")"
KEEP_DAYS="${KEEP_DAYS:-14}"
if ! [ "$KEEP_DAYS" -ge 1 ] 2>/dev/null || [ "$KEEP_DAYS" -gt 14 ]; then
    echo "KEEP_DAYS must be 1..14 (erased accounts must leave the backups, see header)" >&2
    exit 1
fi
umask 077
mkdir -p -m 700 backups
file="backups/pillpal-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
tmp="$file.tmp"
trap 'rm -f "$tmp"' EXIT
docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$tmp"
# pipefail catches a failing pg_dump; the test catches a truncated archive.
gzip -t "$tmp"
mv "$tmp" "$file"
find backups -name 'pillpal-*.sql.gz' -mtime "+$KEEP_DAYS" -delete
echo "backup written: $file"
