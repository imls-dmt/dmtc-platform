#!/usr/bin/env bash
# Poll a health URL until it returns HTTP 200 or the timeout elapses.
# Usage: ./scripts/wait-for-health.sh <url> [timeout-seconds]
set -euo pipefail
URL="${1:?usage: wait-for-health.sh <url> [timeout]}"
TIMEOUT="${2:-180}"
start=$(date +%s)
while :; do
  code=$(curl -sS -o /tmp/health.$$ -w '%{http_code}' -m 10 "$URL" || echo 000)
  if [ "$code" = "200" ]; then
    echo "healthy: $(cat /tmp/health.$$)"; rm -f /tmp/health.$$; exit 0
  fi
  if [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ]; then
    echo "ERROR: $URL still returning $code after ${TIMEOUT}s: $(cat /tmp/health.$$ 2>/dev/null)" >&2
    rm -f /tmp/health.$$; exit 1
  fi
  sleep 5
done
