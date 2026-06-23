#!/usr/bin/env bash
# Import the Solr-only cores into a local stack from a production Solr export.
#
# Usage: ./scripts/import-solr-export.sh [dev|test] <export-dir>
#
# The cores questions, question_groups, surveys, answers and timestamps have no
# MySQL backing, so they cannot be rebuilt by seed-solr.sh. They are populated
# here from JSON files produced on the prod Solr host with, per core:
#
#   curl -sf "http://localhost:8983/solr/<core>/select?q=*:*&rows=<n>&wt=json&omitHeader=true" -o <core>.json
#
# The export files contain real production documents and are intentionally NOT
# committed to git. PII handling on import:
#   - timestamps.ip  -> scrubbed (client IP addresses are personal data)
#   - userid / respondent_id UUIDs -> kept (pseudonymous; preserve referential
#     integrity with the anonymized users/surveys, matching the MySQL sync)
set -euo pipefail

TARGET="${1:-dev}"
EXPORT_DIR="${2:?Usage: $0 <dev|test> <export-dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$TARGET" in
  dev|test) ;;
  *) echo "ERROR: target must be 'dev' or 'test'" >&2; exit 1 ;;
esac
[[ -d "$EXPORT_DIR" ]] || { echo "ERROR: export dir not found: $EXPORT_DIR" >&2; exit 1; }

COMPOSE=(docker compose -p "dmtc-${TARGET}"
    -f "$PLATFORM_DIR/docker-compose.yml"
    -f "$PLATFORM_DIR/docker-compose.${TARGET}.yml"
    --env-file "$PLATFORM_DIR/.env.${TARGET}")

for core in questions question_groups surveys answers timestamps; do
    f="$EXPORT_DIR/${core}.json"
    if [[ ! -f "$f" ]]; then
        echo "→ skip ${core}: no ${core}.json in export dir"
        continue
    fi
    echo "→ importing ${core} from ${f}..."
    "${COMPOSE[@]}" exec -T api python -c '
import sys, json
import dmtclearinghouse as d

core_name = sys.argv[1]
data = json.load(sys.stdin)
docs = data["response"]["docs"] if isinstance(data, dict) else data
for doc in docs:
    doc.pop("_version_", None)
    if core_name == "timestamps":
        doc.pop("ip", None)   # scrub client IP (PII) on import
with d.app.app_context():
    core = getattr(d, core_name)
    core.delete(q="*:*"); core.commit()
    if docs:
        core.add(docs); core.commit()
    n = core.search("*:*", rows=0).raw_response["response"]["numFound"]
    print("   %s: imported %d, solr now %d" % (core_name, len(docs), n))
' "$core" < "$f"
done

echo "→ Solr-only import complete."
