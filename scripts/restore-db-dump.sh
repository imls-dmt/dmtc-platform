#!/usr/bin/env bash
# Import a MySQL/MariaDB dump file into a running stack's database.
#
# Usage: ./scripts/restore-db-dump.sh <dev|test|prod|devsite> <dump.sql[.gz]>
#
# Expects a single-database dump (mysqldump <db>, no --databases flag), as
# produced on the production host with:
#   sudo mysqldump --single-transaction --quick imls | gzip > dmtc-imls-YYYYMMDD.sql.gz
# The tables are imported into the stack's MYSQL_DATABASE regardless of the
# source database name. Existing rows in the same tables are replaced.
set -euo pipefail

TARGET="${1:?Usage: $0 <dev|test|prod|devsite> <dump.sql[.gz]>}"
DUMP="${2:?Usage: $0 <dev|test|prod|devsite> <dump.sql[.gz]>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PLATFORM_DIR/.env.$TARGET"

case "$TARGET" in
  dev|test|prod|devsite) ;;
  *) echo "ERROR: target must be dev, test, prod or devsite" >&2; exit 1 ;;
esac
[[ -f "$DUMP" ]] || { echo "ERROR: dump not found: $DUMP" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

COMPOSE=(docker compose -p "dmtc-$TARGET"
  -f "$PLATFORM_DIR/docker-compose.yml"
  -f "$PLATFORM_DIR/docker-compose.$TARGET.yml"
  --env-file "$ENV_FILE")

if [[ "$DUMP" == *.gz ]]; then
  gzip -t "$DUMP" || { echo "ERROR: $DUMP is truncated or not gzip" >&2; exit 1; }
  reader=(gzip -dc "$DUMP")
else
  reader=(cat "$DUMP")
fi
if "${reader[@]}" | head -c 200000 | grep -q '^CREATE DATABASE'; then
  echo "ERROR: dump contains CREATE DATABASE statements (made with --all-databases or --databases)." >&2
  echo "       Re-export a single database: mysqldump --single-transaction --quick <db>" >&2
  exit 1
fi

echo "→ Importing $DUMP into dmtc-$TARGET database '$MYSQL_DATABASE'"
"${reader[@]}" | "${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
  mysql -u root --default-character-set=utf8mb4 "$MYSQL_DATABASE"
echo "→ Row counts:"
"${COMPOSE[@]}" exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql \
  mysql -u root -N -e "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='$MYSQL_DATABASE' ORDER BY table_name" "$MYSQL_DATABASE" \
  | awk '{printf "   %-22s %s\n", $1, $2}'
