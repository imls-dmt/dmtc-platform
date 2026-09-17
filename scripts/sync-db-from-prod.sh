#!/usr/bin/env bash
# Dump the production MySQL database over SSH, optionally anonymize user PII,
# and import the snapshot into the target local stack (dev or test).
#
# Usage: ./scripts/sync-db-from-prod.sh [dev|test]
#
# Requires: scripts/.env.prod-sync   (SSH/DB credentials for production)
#           .env.dev or .env.test    (credentials for the target local stack)

set -euo pipefail

TARGET="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Load production connection settings ───────────────────────────────────────
PROD_SYNC_ENV="$SCRIPT_DIR/.env.prod-sync"
if [[ ! -f "$PROD_SYNC_ENV" ]]; then
    echo "ERROR: $PROD_SYNC_ENV not found." >&2
    echo "       Copy $SCRIPT_DIR/.env.prod-sync.example and fill in values." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$PROD_SYNC_ENV"

# ── Load target stack settings ────────────────────────────────────────────────
TARGET_ENV="$PLATFORM_DIR/.env.$TARGET"
if [[ ! -f "$TARGET_ENV" ]]; then
    echo "ERROR: $TARGET_ENV not found." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$TARGET_ENV"

# ── Determine target MySQL container and project name ─────────────────────────
case "$TARGET" in
  dev)  COMPOSE_PROJECT="dmtc-dev"  ;;
  test) COMPOSE_PROJECT="dmtc-test" ;;
  *)    echo "ERROR: target must be 'dev' or 'test'" >&2; exit 1 ;;
esac

# ── Dump from production ───────────────────────────────────────────────────────
DUMP_FILE="$(mktemp /tmp/dmtc-prod-dump-XXXXXX.sql)"
trap 'rm -f "$DUMP_FILE"' EXIT

echo "→ Dumping $PROD_DB_NAME from $PROD_SSH_HOST..."
ssh "${PROD_SSH_USER}@${PROD_SSH_HOST}" \
    "mysqldump \
      --host=${PROD_DB_HOST:-localhost} \
      --port=${PROD_DB_PORT:-3306} \
      --user=${PROD_DB_USER} \
      --password=${PROD_DB_PASS} \
      --single-transaction \
      --quick \
      ${PROD_DB_NAME}" \
    > "$DUMP_FILE"

echo "   Dump complete: $(wc -c < "$DUMP_FILE" | tr -d ' ') bytes"

# ── Anonymize user PII (optional) ─────────────────────────────────────────────
# Set ANONYMIZE_USERS=1 in .env.prod-sync to scramble email/name fields so
# production user data is never stored in local developer environments.
if [[ "${ANONYMIZE_USERS:-0}" == "1" ]]; then
    echo "→ Anonymizing user records..."
    # The users table stores rows as JSON blobs in a 'value' column.
    # We replace email addresses with deterministic placeholders derived from
    # the UUID primary key so the data is structurally valid but non-identifying.
    python3 - "$DUMP_FILE" <<'PYEOF'
import sys, re, json, hashlib

dump_path = sys.argv[1]
with open(dump_path, "r", encoding="utf-8", errors="replace") as f:
    content = f.read()

def anonymize_user_insert(match):
    """Replace email/name values inside users INSERT rows."""
    row = match.group(0)
    # Rows look like: ('uuid', 'json-blob')
    inner = re.findall(r"'\s*(\{.*?\})\s*'", row, re.DOTALL)
    for blob in inner:
        try:
            obj = json.loads(blob.replace("\\'", "'"))
        except json.JSONDecodeError:
            continue
        uid = obj.get("uuid", obj.get("id", "unknown"))
        tag = hashlib.sha1(uid.encode()).hexdigest()[:8]
        if "email" in obj:
            obj["email"] = f"anon-{tag}@example.invalid"
        for field in ("first_name", "last_name", "display_name", "name"):
            if field in obj:
                obj[field] = f"Anon-{tag}"
        try:
            row = row.replace(blob, json.dumps(obj))
        except Exception:
            pass
    return row

content = re.sub(
    r"INSERT INTO `users`[^\n]+",
    anonymize_user_insert,
    content,
    flags=re.DOTALL,
)
with open(dump_path, "w", encoding="utf-8") as f:
    f.write(content)
print("   Anonymization complete.")
PYEOF
fi

# ── Import into target stack ───────────────────────────────────────────────────
echo "→ Importing into $TARGET stack (project: $COMPOSE_PROJECT)..."
docker compose -p "$COMPOSE_PROJECT" \
    -f "$PLATFORM_DIR/docker-compose.yml" \
    -f "$PLATFORM_DIR/docker-compose.$TARGET.yml" \
    --env-file "$TARGET_ENV" \
    exec -T mysql \
    mysql \
      --user="$MYSQL_USER" \
      --password="$MYSQL_PASSWORD" \
      "$MYSQL_DATABASE" \
    < "$DUMP_FILE"

echo "→ Import complete."
echo ""
echo "   Next step: trigger a Solr reindex so search reflects the new data."
echo "   Run:  make ${TARGET}-reindex DMTC_ADMIN_USER=<user> DMTC_ADMIN_PASS=<pass>"
