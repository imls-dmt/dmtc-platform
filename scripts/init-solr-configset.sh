#!/bin/bash
# Seed the _default configset into the Solr home.
#
# The stock solr image ships the _default configset only under
# /opt/solr/server/solr/configsets/. The core-admin CREATE call used by
# init-solr.sh (action=CREATE&configSet=_default) resolves configSet names
# against the Solr home ($SOLR_HOME/configsets), which starts empty on a
# fresh volume — so every core creation fails with
# "Could not load configuration from directory .../configsets/_default".
#
# This runs via /docker-entrypoint-initdb.d before Solr starts, copying the
# configset into place so core creation can find it.
set -e

TARGET="/var/solr/data/configsets/_default"
SOURCE="/opt/solr/server/solr/configsets/_default"

if [ ! -d "$TARGET" ]; then
    mkdir -p /var/solr/data/configsets
    cp -r "$SOURCE" "$TARGET"
    echo "init-solr-configset: copied _default configset into Solr home."
else
    echo "init-solr-configset: _default configset already present — skipping."
fi
