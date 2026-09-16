#!/bin/sh
# Creates all required Solr cores if they don't already exist.
# Runs once via the solr-init service after Solr passes its healthcheck.

SOLR_URL="http://solr:8983/solr"

CORES="learningresources users taxonomies feedback questions question_groups surveys answers timestamps"

for core in $CORES; do
    # Check if core already exists
    status=$(curl -sf "${SOLR_URL}/admin/cores?action=STATUS&core=${core}" | grep -c '"uptime"' || true)
    if [ "$status" -gt 0 ]; then
        echo "Core '${core}' already exists — skipping."
    else
        # Each core has a dedicated configset of the same name (the canonical
        # DMTC schema installed by init-solr-configset.sh).
        echo "Creating core '${core}' (configSet=${core})..."
        curl -sf "${SOLR_URL}/admin/cores?action=CREATE&name=${core}&instanceDir=${core}&configSet=${core}" \
            && echo "  → created." \
            || echo "  → failed (may already exist or configset missing — check Solr logs)."
    fi
done

echo "Solr core initialisation complete."
