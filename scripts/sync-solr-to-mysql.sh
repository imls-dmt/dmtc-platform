#!/usr/bin/env bash
# Back up the Solr-primary cores into their MySQL tables (Solr -> MySQL).
#
# Usage: ./scripts/sync-solr-to-mysql.sh [dev|test]
#
# Mirrors questions, question_groups, surveys and answers from Solr into their
# MySQL backup tables by calling the app's solr_to_mysql() inside the api
# container (app context, no auth). Solr stays the primary store; this gives
# disaster recovery and lets `seed-solr.sh` rebuild those cores from MySQL.
# Eventually-consistent — run it periodically and/or before a DB backup.
# (timestamps is intentionally not backed up.)
set -euo pipefail

TARGET="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$TARGET" in
  dev|test) ;;
  *) echo "ERROR: target must be 'dev' or 'test'" >&2; exit 1 ;;
esac

docker compose -p "dmtc-${TARGET}" \
    -f "$PLATFORM_DIR/docker-compose.yml" \
    -f "$PLATFORM_DIR/docker-compose.${TARGET}.yml" \
    --env-file "$PLATFORM_DIR/.env.${TARGET}" \
    exec -T api python -c '
import json
import dmtclearinghouse as d
with d.app.app_context():
    print(json.dumps(d.solr_to_mysql(), indent=2))
'
