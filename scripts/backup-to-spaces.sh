#!/usr/bin/env bash
# Nightly backup of a running DMTC stack to a DigitalOcean Spaces bucket.
#
# Usage: ./scripts/backup-to-spaces.sh [prod|devsite]
#
# 1. Mirrors the Solr-primary cores into their MySQL backup tables
#    (solr_to_mysql() inside the api container), so the dump below is a
#    complete copy of the platform's data.
# 2. mysqldump of the stack's database, gzipped.
# 3. Uploads to s3://$SPACES_BUCKET/<target>/ with rclone and prunes copies
#    older than BACKUP_RETENTION_DAYS.
#
# Reads SPACES_* and BACKUP_RETENTION_DAYS from .env.<target>. Installed as a
# cron job by dev-vm/cloud-init-prod.yaml; run by hand any time.
set -euo pipefail

TARGET="${1:-prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PLATFORM_DIR/.env.$TARGET"

case "$TARGET" in
  prod|devsite) ;;
  *) echo "ERROR: target must be 'prod' or 'devsite'" >&2; exit 1 ;;
esac
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${SPACES_BUCKET:?SPACES_BUCKET missing in $ENV_FILE}"
: "${SPACES_REGION:?SPACES_REGION missing in $ENV_FILE}"
: "${SPACES_ACCESS_KEY:?SPACES_ACCESS_KEY missing in $ENV_FILE}"
: "${SPACES_SECRET_KEY:?SPACES_SECRET_KEY missing in $ENV_FILE}"
RETENTION="${BACKUP_RETENTION_DAYS:-30}"

COMPOSE=(docker compose -p "dmtc-$TARGET"
  -f "$PLATFORM_DIR/docker-compose.yml"
  -f "$PLATFORM_DIR/docker-compose.$TARGET.yml"
  --env-file "$ENV_FILE")

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DUMP="$WORK/dmtc-$TARGET-$STAMP.sql.gz"

echo "[$STAMP] $TARGET: syncing Solr-primary cores into MySQL"
"${COMPOSE[@]}" exec -T api python -c '
import json, dmtclearinghouse as d
with d.app.app_context():
    print(json.dumps(d.solr_to_mysql()))
'

echo "[$STAMP] $TARGET: dumping MySQL database $MYSQL_DATABASE"
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" mysql \
  mysqldump --single-transaction --quick --routines --triggers \
  -u "$MYSQL_USER" "$MYSQL_DATABASE" | gzip -9 > "$DUMP"
echo "  $(du -h "$DUMP" | cut -f1) written"

# rclone remote defined entirely through environment variables (no config file).
export RCLONE_CONFIG_SPACES_TYPE=s3
export RCLONE_CONFIG_SPACES_PROVIDER=DigitalOcean
export RCLONE_CONFIG_SPACES_ACCESS_KEY_ID="$SPACES_ACCESS_KEY"
export RCLONE_CONFIG_SPACES_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY"
export RCLONE_CONFIG_SPACES_ENDPOINT="${SPACES_REGION}.digitaloceanspaces.com"
export RCLONE_CONFIG_SPACES_ACL=private

echo "[$STAMP] $TARGET: uploading to spaces:$SPACES_BUCKET/$TARGET/"
rclone copy "$DUMP" "spaces:$SPACES_BUCKET/$TARGET/" --s3-no-check-bucket
echo "[$STAMP] $TARGET: pruning copies older than $RETENTION days"
rclone delete "spaces:$SPACES_BUCKET/$TARGET/" --min-age "${RETENTION}d" --include "dmtc-$TARGET-*.sql.gz"
echo "[$STAMP] $TARGET: done. Latest copies:"
rclone lsl "spaces:$SPACES_BUCKET/$TARGET/" | tail -3
