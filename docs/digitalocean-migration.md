# Migrating DMTC hosting to DigitalOcean

Status: **proposal, 2026-09-16**. Nothing in this document has been provisioned
except the uptime checks described in the Monitoring section.

## Why move

The production and development sites, the API and the legacy
`dmtclearinghouse.esipfed.org` name all resolve to one UNM server
(129.24.196.224). A live probe on 2026-09-16 found:

| Component | Observed |
|---|---|
| OS / web server | CentOS 7 (end of life June 2024), Apache 2.4.6, OpenSSL 1.0.2k, mod_wsgi on Python 3.6 (end of life Dec 2021) |
| Solr-backed API endpoints | HTTP 500 on all hostnames (search, resource lookup, vocabularies, surveys, RSS); session endpoints fine |
| HTTP to HTTPS redirect | Drops the slash between host and path, breaking every non-https deep link (UI issue #101) |
| `dmtc-devel.org` | Redirects to the legacy ESIP host; serves a certificate for `esip-dev-02.edacnm.org` |
| `dmtc-prod.org` (apex) | No certificate; only `www` is covered |
| ORCID sign-in | 500 on production: the API needs an `X-Forwarded-Host` header the proxy does not send |
| Monitoring | None. The outage above was found by accident. |

The June 2026 API security fixes (commit 8c4a6bd on `imls-dmt-api` devel) are
not deployed. The Docker stack in this repository already runs the whole
platform and is the deployment unit for the new host, so the migration is
mostly provisioning, data transfer and DNS rather than new software.

## Target architecture

One Droplet running the existing Compose stack, fronted by Caddy for TLS.

```
                Hover DNS (or DO DNS)
   dmtc-prod.org, www.dmtc-prod.org ─┐
   dmtc-devel.org, www.dmtc-devel.org ┘──► Reserved IP ──► Droplet (Ubuntu 24.04)
                                                             │
                                          caddy :80/:443 ────┤ auto Let's Encrypt for all four names
                                            │                │ sets X-Forwarded-Host / -Proto
                                            ├─► ui (nginx)   │ prod compose project
                                            ├─► api (gunicorn) ─► solr 8.11.1, mysql 8
                                            └─► ui-dev / api-dev  (second compose project, dmtc-devel.org)
```

| Item | Choice | Monthly (USD, list price) |
|---|---|---|
| Droplet `s-4vcpu-8gb`, 160 GB SSD, region `nyc3` or `sfo3` | Solr + MySQL + API + two UI builds fit comfortably; 4 GB would be tight for Solr | 48 |
| Droplet backups (weekly, DO-managed) | Whole-disk restore point; 20% of droplet price | ~10 |
| Reserved IP | Lets the droplet be rebuilt without a DNS change | 0 while attached |
| Spaces bucket for nightly `mysqldump` + Solr export | Off-droplet copy of the data; first 250 GB included | 5 |
| Uptime checks (2 today, up to 4 after cutover) | HTTPS checks from two US regions with email alerts | see DO pricing page |
| Cloud firewall, monitoring agent, alert policies | Included | 0 |
| **Estimated total** | | **~65 to 70** |

Not recommended initially: DO Managed MySQL (15/mo). MySQL is the backup
store in this architecture; Solr is the primary read path. A managed database
adds cost without addressing the component that actually failed.

Development hosting: run the dev stack as a second Compose project on the same
droplet (ports 8082 etc. behind Caddy on `dmtc-devel.org`). Split it onto a
separate `s-2vcpu-4gb` droplet (24/mo) only if dev work starts affecting
production.

## What has to be built in this repository first

1. **`docker-compose.prod.yml`** overriding the base stack: adds a `caddy`
   service (ports 80/443, `Caddyfile` with the four hostnames, reverse proxy to
   `ui:80`, `header_up X-Forwarded-Host {host}`), removes the `ui` port
   publication, pins `restart: always`, and mounts named volumes for
   `caddy_data`, `mysql_data`, `solr_data`.
2. **`.env.prod.example`** with every variable the API needs, including
   `ORCID_REDIRECT_URL=https://www.dmtc-prod.org/api/orcid_sign_in/orcid_callback`
   and `FRONT_END_URL=https://www.dmtc-prod.org`.
3. **`dev-vm/cloud-init-prod.yaml`** derived from `dev-vm/cloud-init.yaml`:
   Docker only (no Node, no Claude Code), a `dmtc` deploy user with the two SSH
   keys already on the DO account, unattended-upgrades, and the DO monitoring
   agent.
4. **`scripts/backup-to-spaces.sh`** and a cron entry: nightly `mysqldump` plus
   `sync-solr-to-mysql.sh`, uploaded with `s3cmd`/`rclone` to the Spaces bucket,
   30-day retention.
5. **Makefile targets** `prod-up`, `prod-down`, `prod-logs`, `prod-deploy`
   (git pull on the three repos, `docker compose build`, `up -d`, health wait).
6. **API health endpoint** (`imls-dmt-api`): `GET /api/health` that pings Solr
   and MySQL and returns 200 or 503 with a JSON body. Uptime checks then
   exercise dependencies without depending on a specific record id.
7. **Fix in the API for the ORCID callback**: fall back to `request.host` when
   `X-Forwarded-Host` is absent (`dmtclearinghouse.py` line 3591), so sign-in
   cannot 500 on a proxy misconfiguration.

## Migration steps

1. **Prepare** the items above on `devel`, test with `make test-up` locally.
2. **Provision**: `doctl compute droplet create dmtc-prod --size s-4vcpu-8gb
   --image ubuntu-24-04-x64 --region nyc3 --ssh-keys <ids> --user-data-file
   dev-vm/cloud-init-prod.yaml --enable-backups --enable-monitoring`; attach a
   reserved IP; create a cloud firewall allowing 22 (from your addresses only),
   80 and 443.
3. **Export data from the UNM host** (needs SSH access; `scripts/sync-db-from-prod.sh`
   and `scripts/import-solr-export.sh` already cover the mechanics): `mysqldump`
   of the DMTC database and a Solr export of all nine cores. If Solr on the old
   host stays down, copy `/var/solr/data` directly and index it into the new
   Solr 8.11.1 with the canonical configsets in `solr/configsets/`.
4. **Stage** on the reserved IP with a local hosts-file override for
   `www.dmtc-prod.org`. Verify search, resource pages, local login, submission,
   workflow status change (API issue #110), RSS.
5. **ORCID**: in the ORCID developer console, add
   `https://www.dmtc-prod.org/api/orcid_sign_in/orcid_callback/www.dmtc-prod.org`
   and the `dmtc-devel.org` equivalent as redirect URIs for client
   `APP-SCZZMT87KMLN7QZM`. Test sign-in on the staged host.
6. **Cut over**: lower TTLs at Hover to 300 s a day ahead; point the A records
   for all four names at the reserved IP; Caddy issues certificates on first
   request. Confirm the uptime checks go green. Keep the UNM host untouched for
   two weeks as a fallback.
7. **Legacy name**: ask ESIP to point `dmtclearinghouse.esipfed.org` at
   `www.dmtc-prod.org` (CNAME or Cloudflare redirect). This closes UI issue #71.
8. **Close out**: UI issues #74, #95, #98, #99, #101 and API #106 to #109 are
   all resolved by this move; update the board.

Optionally move DNS for `dmtc-prod.org` and `dmtc-devel.org` from Hover to DO
DNS so records are managed with `doctl` alongside everything else.

## Monitoring and notification

Created on 2026-09-16 with `doctl monitoring uptime`, against the **current**
production host so alerts work before and after the move. Retarget the API
check to `/api/health` once that endpoint exists.

| Check | Target | Alerts (email to the DO account address) |
|---|---|---|
| DMTC production API (Solr-backed) | `https://www.dmtc-prod.org/flask/api/resources/?id=b388173a-…` | down for 2 min; latency over 5 s for 10 min |
| DMTC production UI | `https://www.dmtc-prod.org/` | down for 2 min; certificate expiring within 14 days |

Both checks run from `us_east` and `us_west`. To add a Slack channel:
`doctl monitoring uptime alert update <alert-id> --slack-channels <name>
--slack-urls <webhook>`. After the move, add droplet resource alerts
(`doctl monitoring alert create --type v1/insights/droplet/cpu` etc.) for CPU,
memory and disk at 85%.

## Decisions needed before provisioning

- Region: `nyc3` (closest to ESIP and most East-coast users) or `sfo3`.
- Backups: DO weekly droplet backups (simple, +20%) versus snapshots on a
  schedule (cheaper, manual).
- DNS: stay at Hover or move to DO DNS.
- Notification channel beyond email: Slack webhook, and whether a second
  address should receive alerts.
- Access to the UNM host for the data export, and who holds the ORCID client
  secret.
- Development stack on the same droplet or its own.
