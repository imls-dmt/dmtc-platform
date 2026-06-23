#!/bin/bash
# Seed Solr configsets into the Solr home before cores are created.
#
# Two sources are copied into $SOLR_HOME/configsets so that init-solr.sh can
# create cores with action=CREATE&configSet=<name>:
#
#   1. The canonical per-core DMTC configsets, committed under
#      dmtc-platform/solr/configsets/ and mounted read-only at /dmtc-configsets.
#      These carry the real production schemas (extracted from prod Solr 8.11.1).
#   2. The stock _default configset (fallback for any core without a dedicated
#      configset), which ships only under /opt/solr/server/solr/configsets/.
#
# Runs via /docker-entrypoint-initdb.d before Solr starts.
set -e

CONFIGSETS_HOME="/var/solr/data/configsets"
mkdir -p "$CONFIGSETS_HOME"

# 1. Canonical DMTC configsets (mounted from the repo).
if [ -d /dmtc-configsets ]; then
    for src in /dmtc-configsets/*/; do
        [ -d "$src" ] || continue
        name="$(basename "$src")"
        # Refresh on every start so repo edits to schemas take effect.
        rm -rf "$CONFIGSETS_HOME/$name"
        cp -r "$src" "$CONFIGSETS_HOME/$name"
        echo "init-solr-configset: installed configset '$name'."
    done
fi

# 2. Stock _default fallback.
if [ ! -d "$CONFIGSETS_HOME/_default" ]; then
    cp -r /opt/solr/server/solr/configsets/_default "$CONFIGSETS_HOME/_default"
    echo "init-solr-configset: installed stock _default configset."
fi
