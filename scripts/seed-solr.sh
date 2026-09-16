#!/usr/bin/env bash
# Bootstrap-seed the Solr cores of a local stack from the MySQL backup blobs.
#
# Usage: ./scripts/seed-solr.sh [dev|test]
#
# This rebuilds the MySQL-backed cores (learningresources, users, taxonomies,
# feedback) by calling the app's reindex() inside the api container, in an app
# context. Unlike `make dev-reindex` (which drives the @login_required HTTP
# route and therefore needs an already-populated users core to log in), this
# path requires no authentication and so works on a fresh/empty stack — run it
# right after `make sync-db-dev`.
#
# Solr-only cores (questions, question_groups, surveys, answers, timestamps)
# have no MySQL backing and are not touched here; they are populated from a
# prod Solr document export.
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
    print(json.dumps(d.reindex(), indent=2))
'
