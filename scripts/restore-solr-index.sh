#!/usr/bin/env bash
# Restore Solr index data from a tarball of the production /var/solr/data
# directory into a running stack's Solr volume, core by core.
#
# Usage: ./scripts/restore-solr-index.sh <dev|test|prod|devsite> <dmtc-solr-data-YYYYMMDD.tgz>
#
# Only each core's data/ directory (Lucene index + transaction log) is copied.
# The core's configuration keeps coming from solr/configsets/ (the hardened
# configsets extracted from production), so nothing in the old solrconfig.xml
# (Velocity, Tika, contrib <lib> entries) is reintroduced. Cores present in the
# tarball but not provisioned by init-solr.sh (e.g. testcore) are skipped.
#
# Solr is stopped for the copy and restarted afterwards; the api container
# will reconnect on its own.
set -euo pipefail

TARGET="${1:?Usage: $0 <dev|test|prod|devsite> <tarball>}"
TARBALL="${2:?Usage: $0 <dev|test|prod|devsite> <tarball>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

case "$TARGET" in
  dev|test|prod|devsite) ;;
  *) echo "ERROR: target must be dev, test, prod or devsite" >&2; exit 1 ;;
esac
[[ -f "$TARBALL" ]] || { echo "ERROR: tarball not found: $TARBALL" >&2; exit 1; }
gzip -t "$TARBALL" || { echo "ERROR: $TARBALL is not a valid gzip file" >&2; exit 1; }

COMPOSE=(docker compose -p "dmtc-$TARGET"
  -f "$PLATFORM_DIR/docker-compose.yml"
  -f "$PLATFORM_DIR/docker-compose.$TARGET.yml"
  --env-file "$PLATFORM_DIR/.env.$TARGET")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "→ Extracting $TARBALL"
tar xzf "$TARBALL" -C "$WORK"
SRC="$WORK/data"
[[ -d "$SRC" ]] || { echo "ERROR: tarball does not contain a top-level data/ directory" >&2; exit 1; }

echo "→ Stopping Solr in dmtc-$TARGET"
"${COMPOSE[@]}" stop solr

restored=0; skipped=()
for coredir in "$SRC"/*/; do
  core="$(basename "$coredir")"
  [[ -f "$coredir/core.properties" && -d "$coredir/data" ]] || continue
  # Does the stack provision this core? (init-solr.sh creates a directory per core in the volume.)
  if ! "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh solr -c "test -f /var/solr/data/$core/core.properties"; then
    skipped+=("$core"); continue
  fi
  echo "   $core: $(find "$coredir/data" -type f | wc -l | tr -d ' ') files"
  # Replace only the data/ subdirectory of the core; leave conf/ and core.properties alone.
  tar czf - -C "$coredir" data \
    | "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh solr -c \
        "rm -rf /var/solr/data/$core/data && tar xzf - -C /var/solr/data/$core && chown -R solr:solr /var/solr/data/$core/data"
  restored=$((restored+1))
done

echo "→ Starting Solr"
"${COMPOSE[@]}" start solr
echo "→ Waiting for Solr to load cores"
for _ in $(seq 1 30); do
  if "${COMPOSE[@]}" exec -T solr curl -sf 'http://localhost:8983/solr/admin/cores?action=STATUS&wt=json' > "$WORK/status.json" 2>/dev/null; then break; fi
  sleep 3
done
python3 - "$WORK/status.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
fails = d.get("initFailures", {})
for name, core in sorted(d.get("status", {}).items()):
    print(f"   {name:20} docs={core.get('index', {}).get('numDocs', '?')}")
if fails:
    print("ERROR: cores failed to load:", json.dumps(fails, indent=2)); sys.exit(1)
PY
echo "→ Restored $restored core(s)." 
[[ ${#skipped[@]} -eq 0 ]] || echo "   Skipped (not provisioned in this stack): ${skipped[*]}"
