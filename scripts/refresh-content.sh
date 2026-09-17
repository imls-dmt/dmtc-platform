#!/usr/bin/env bash
# Fast-forward the ui-static-content checkout that Caddy serves for /source/*
# and /images/*. Run by cron every five minutes on the droplet; safe by hand.
# Prints a line only when something changed, so the log stays quiet.
set -euo pipefail
DIR="${CONTENT_DIR:-/opt/dmtc/ui-static-content}"
[[ -d "$DIR/.git" ]] || { echo "ERROR: $DIR is not a git checkout" >&2; exit 1; }
before=$(git -C "$DIR" rev-parse HEAD)
git -C "$DIR" fetch -q origin
git -C "$DIR" merge -q --ff-only "origin/$(git -C "$DIR" rev-parse --abbrev-ref HEAD)" 2>/dev/null \
  || { echo "$(date -u +%FT%TZ) ERROR: fast-forward failed in $DIR (local changes?)" >&2; exit 1; }
after=$(git -C "$DIR" rev-parse HEAD)
[[ "$before" == "$after" ]] || echo "$(date -u +%FT%TZ) content updated ${before:0:7} -> ${after:0:7}"
