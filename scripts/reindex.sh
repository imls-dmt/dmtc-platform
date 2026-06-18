#!/usr/bin/env bash
# Authenticate against the DMTC API and trigger a full Solr reindex.
#
# Usage: ./scripts/reindex.sh <base_url> <admin_user> <admin_pass>
#
# Example:
#   ./scripts/reindex.sh http://localhost:8082 admin@example.org secretpass
#
# The script is also called by the Makefile targets dev-reindex and test-reindex.

set -euo pipefail

BASE_URL="${1:?Usage: $0 <base_url> <admin_user> <admin_pass>}"
ADMIN_USER="${2:?admin_user required}"
ADMIN_PASS="${3:?admin_pass required}"

API="${BASE_URL%/}/api"

echo "→ Logging in as $ADMIN_USER..."
COOKIE_JAR="$(mktemp /tmp/dmtc-cookies-XXXXXX)"
trap 'rm -f "$COOKIE_JAR"' EXIT

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -c "$COOKIE_JAR" \
    -X POST "$API/user/login/" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}")

if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "ERROR: Login failed (HTTP $HTTP_STATUS)." >&2
    exit 1
fi
echo "   Login successful."

echo "→ Triggering reindex at $API/admin/reindex/..."
REINDEX_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_JAR" \
    -X POST "$API/admin/reindex/")

if [[ "$REINDEX_STATUS" == "200" || "$REINDEX_STATUS" == "202" ]]; then
    echo "   Reindex triggered (HTTP $REINDEX_STATUS). Solr cores are rebuilding."
else
    echo "ERROR: Reindex returned HTTP $REINDEX_STATUS." >&2
    exit 1
fi
