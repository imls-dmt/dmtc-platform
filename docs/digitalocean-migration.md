# Migrating DMTC hosting to DigitalOcean

Status: **staged and verified 2026-09-17.** Droplet `dmtc-prod` (id 601272917,
nyc3, s-4vcpu-8gb, reserved IP 134.199.249.40) runs the full stack with the
production data restored; every endpoint answers correctly through Caddy with
staging (self-signed) certificates. DNS has not moved. Remaining before
cutover is listed at the end. Decisions taken: region `nyc3`; DO weekly droplet backups;
DNS stays at Hover; email-only alerts (to kbene@karlbenedict.com once that
address is added to the DO team); development site on the same droplet as a
second compose project. Uptime checks exist against the current host.

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

## What has been built in this repository (devel, 2026-09-16)

| Piece | File | Notes |
|---|---|---|
| Production compose override | `docker-compose.prod.yml` | Adds Caddy (80/443, TLS, HTTP->HTTPS with path preserved), removes the ui port, `restart: always`, Solr heap 1g |
| Caddy configuration | `caddy/Caddyfile`, `caddy/sites/prod.caddy`, `caddy/sites/devsite.caddy`, `caddy/sites/legacy.caddy.example` | One file per site; apex names redirect to www; security headers; `X-Forwarded-Host` passed through for ORCID |
| Development-site override | `docker-compose.devsite.yml` | Second project `dmtc-devsite` with its own MySQL/Solr volumes, joins the `dmtc-edge` network as `ui-devsite`, no published ports |
| Environment templates | `.env.prod.example`, `.env.devsite.example` | Every API variable plus hostnames, ACME contact, Spaces credentials |
| Droplet provisioning | `dev-vm/cloud-init-prod.yaml` | `dmtc` deploy user with the account's SSH keys, Docker, rclone, DO metrics agent, ufw, fail2ban, unattended-upgrades, 2 GB swap, repo clones under `/opt/dmtc`, nightly backup cron |
| Backups | `scripts/backup-to-spaces.sh` | Solr->MySQL sync, `mysqldump`, gzip, rclone upload to Spaces, prune after `BACKUP_RETENTION_DAYS` |
| Operations | `Makefile` targets `prod-*` and `devsite-*`, `scripts/wait-for-health.sh` | `make prod-deploy` pulls the release branches of all three repos, rebuilds, restarts, waits for `/api/health` |
| Validation | `.github/workflows/platform-ci.yml` | Renders every compose combination, shellcheck, cloud-init YAML, `caddy validate` |
| API health endpoint | `imls-dmt-api` devel: `GET /api/health` | Pings Solr core and MySQL; 200 or 503 with JSON detail; rate-limit exempt |
| API ORCID fix | `imls-dmt-api` devel: `orcid_sign_in()` | Falls back to `request.host` when `X-Forwarded-Host` is absent; the production 500 cannot recur |

### Original build list (for reference)

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
7. **Legacy name** (`dmtclearinghouse.esipfed.org`, owned by ESIP, currently
   Cloudflare-proxied to the UNM server). Proposed model, designed so ESIP is
   asked exactly once and never again:

   - We add an A record in the Hover zone we control:
     `legacy.dmtc-prod.org -> <reserved IP>`.
   - ESIP replaces their record with a single **DNS-only (grey-cloud) CNAME**:
     `dmtclearinghouse.esipfed.org CNAME legacy.dmtc-prod.org`.
   - Caddy on our droplet (`caddy/sites/legacy.caddy`) obtains a certificate
     for the ESIP name, since traffic now reaches us, and answers every request
     with a `301` to `https://www.dmtc-prod.org` preserving path and query, so
     old bookmarks, citations and search-engine links keep working. If the
     destination ever changes, it is a one-line edit on our side.

   If ESIP prefers not to CNAME to an external zone, the fallback is a
   Cloudflare **Redirect Rule** on their side (`dmtclearinghouse.esipfed.org/*`
   -> `https://www.dmtc-prod.org/${1}`, 301, preserve query string) with the
   DNS record left proxied and pointing anywhere; that also needs no
   certificate work from anyone, but future changes need an ESIP ticket. A
   CNAME to `www.dmtc-prod.org` directly is **not** recommended: Caddy would
   then have to serve the site itself under the ESIP name (split identity,
   duplicate content) rather than redirect. This closes UI issue #71.
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

## Decisions (taken 2026-09-16)

| Question | Decision |
|---|---|
| Region | `nyc3` |
| Backups | DO weekly droplet backups (+20%), plus nightly database dumps to Spaces |
| DNS | Stays at Hover |
| Notifications | Email only, to kbene@karlbenedict.com. DO only accepts team-member addresses: add it under Settings > Team (or make it the account email) and then run `doctl monitoring uptime alert update ... --emails kbene@karlbenedict.com` for the four alerts |
| Development site | Same droplet, separate compose project (`make devsite-up`), served by the production Caddy on dmtc-devel.org |
| UNM host access | Available (SSH) for the data export |
| ORCID client secret | On the UNM host; to be located. Auth model reviewed below |

## ORCID authentication: current options and what to change

Reviewed against ORCID's live documentation and discovery document on
2026-09-16 (sources in the footnotes of this section).

**What has changed since the integration was built.** ORCID still has only two
tiers, Public (free, non-members) and Member (paid). The Public API remains
free and remains the recommended way to offer "Sign in with ORCID". Changes
that matter to DMTC: Public API traffic is now capped at 12 requests/second
and 100,000 reads per day per client (Feb 2025), the Public API terms were
revised in Oct 2024 to non-commercial use only (DMTC qualifies), a
self-service Developer Tools page now manages redirect URIs (July 2023), and
ORCID replaced its OAuth server in April 2026 (same protocol, new error
payloads). PKCE is still not supported; the implicit flow is still permitted
but not recommended. API v3.0 is the recommended version; v2.1, which DMTC
reads for the user's name, is still served but is a legacy version ORCID
reserves the right to charge for once retired.

**Governance point.** Public API credentials are tied to one individual's
ORCID record and cannot be transferred. Whoever registered client
`APP-SCZZMT87KMLN7QZM` is the only person who can edit its redirect URIs. Confirm
who that is before cutover.

**Recommendation.** Keep the current 3-legged authorization-code flow with
`scope=openid` and server-side `client_secret_post`; it is exactly what ORCID
recommends for non-members and nothing better is on offer. Make three changes
in the API:

1. Stop calling `pub.orcid.org/v2.1/{orcid}/record` after login. The token
   response already carries `orcid` and `name`, and the `id_token` (RS256,
   verifiable against `https://orcid.org/oauth/jwks`) carries `sub`,
   `given_name`, `family_name`. Use those, or `GET https://orcid.org/oauth/userinfo`
   with the bearer token. This removes the v2.1 dependency entirely.
2. Send a CSRF-bound `state` and a `nonce` on the authorize request and verify
   both on callback. This is the standards-based mitigation ORCID expects in
   the absence of PKCE.
3. Read the ORCID issuer from configuration so the dev site can use the
   sandbox (`https://sandbox.orcid.org`, free, separate client credentials,
   accepts `http://localhost` redirect URIs) while production uses
   `https://orcid.org`.

**Redirect URIs for the move.** In Developer Tools (pencil icon on the DMTC
client, "Add another redirect URI"), register the full callback paths:
`https://www.dmtc-prod.org/api/orcid_sign_in/orcid_callback/www.dmtc-prod.org`
and `https://www.dmtc-devel.org/api/orcid_sign_in/orcid_callback/www.dmtc-devel.org`.
Subdomains are separate registrations, wildcards are not allowed, HTTPS only.
Keep the legacy ESIP callback registered until cutover is complete.

Sources: Public API overview <https://info.orcid.org/documentation/features/public-api/>;
rate limits <https://info.orcid.org/faq/what-are-the-api-limits/>; terms
<https://info.orcid.org/public-client-terms-of-service/>; scopes
<https://info.orcid.org/ufaqs/what-is-an-oauth-scope-and-which-scopes-does-orcid-support/>;
redirect URIs <https://info.orcid.org/ufaqs/how-do-redirect-uris-work/>;
version policy <https://info.orcid.org/ufaqs/sunsetting-api-version-2/>;
OIDC reference <https://github.com/ORCID/ORCID-Source/blob/main/orcid-web/ORCID_AUTH_WITH_OPENID_CONNECT.md>;
discovery <https://orcid.org/.well-known/openid-configuration>;
sandbox <https://info.orcid.org/documentation/integration-guide/sandbox-testing-server/>.

## Provisioned resources (2026-09-16)

| Resource | Value |
|---|---|
| Droplet | `dmtc-prod`, id **601272917**, nyc3, `s-4vcpu-8gb`, Ubuntu 24.04, tags `dmtc,prod`, backups + monitoring on. Provisioned with `dev-vm/setup-prod.sh` over SSH after the first attempt's cloud-init was rejected (non-ASCII bytes in user-data; fixed, CI-guarded). |
| Orphaned droplet | id 601271964 (167.71.187.71), empty, must be deleted in the DO console: the doctl token cannot delete droplets |
| Public IPv4 (ephemeral) | 165.227.126.172 |
| Reserved IP (use this in DNS) | **134.199.249.40** |
| Cloud firewall | `dmtc-prod-fw` (tag `dmtc`): in 22/tcp, 80/tcp, 443/tcp, 443/udp; all out |
| Deploy user | `dmtc` (SSH keys from the DO account), repos under `/opt/dmtc` |
| Spaces | bucket `dmtc-backups` (nyc3), created by the first backup run; bootstrap key `dmtc-backups-bootstrap` (full access) to be replaced by a bucket-scoped key once the bucket exists, then deleted |
| Uptime checks | API `0a0a9b26-…`, UI `37e5df47-…` (currently pointed at the UNM host) |

`.env.prod` was generated locally in this directory (gitignored) with fresh
`FLASK_SECRET_KEY` and MySQL passwords, `MYSQL_DATABASE=imls` to match the
production dump, `ACME_EMAIL`, and the Spaces credentials. ORCID values are
still blank. Copy it to `/opt/dmtc/dmtc-platform/.env.prod` on the droplet.

## Data export (2026-09-16, from the UNM host)

- `backup/dmtc-solr-data-20260916.tgz` (3.1 MB): full `/var/solr/data`, ten
  cores, verified. Restore with `make prod-restore-solr TARBALL=...`.
- `backup/dmtc-mysql-20260916.sql.gz`: `--all-databases` dump, arrived
  truncated. Re-export as a single database:
  `sudo mysqldump --single-transaction --quick imls | gzip > ~/dmtc-imls-YYYYMMDD.sql.gz`
  and restore with `make prod-restore-db DUMP=...`. The API uses only `imls`
  (tables feedback, learningresources, taxonomies, tokens, users); `dmt` and
  `imls_nightly` are legacy Drupal-era databases and are not migrated.

## Staging verification (2026-09-17)

Data restored with `scripts/restore-db-dump.sh` and `scripts/restore-solr-index.sh`:
MySQL `imls` 942 learningresources / 866 users / 26 taxonomies / 32 feedback /
11 tokens; Solr cores learningresources 942, surveys 921, users 804, timestamps
659, answers 102, questions 75, taxonomies 24, question_groups 2, feedback 0
(all matching the UNM host). Tested from outside with host overrides
(`curl --resolve www.dmtc-prod.org:443:134.199.249.40 -k`):

| Check | Result |
|---|---|
| UI index, SPA deep link `/resource/<id>`, `/source/home.json` (submodule content) | 200 |
| `/api/health` | 200 `{"mysql":"ok","solr":"ok"}` |
| Resource by id, default search (hits-total 670, same as the UNM host), RSS, vocabularies | 200 |
| `http://www.dmtc-prod.org/search?x=1` | 308 to `https://www.dmtc-prod.org/search?x=1` (path preserved: fixes UI #101) |
| `https://dmtc-prod.org/resource/abc` | 301 to `https://www.dmtc-prod.org/resource/abc` |
| `/api/orcid_sign_in` | 302 to ORCID with callback `https://www.dmtc-prod.org/api/orcid_sign_in/orcid_callback/www.dmtc-prod.org` (client id still empty) |
| Headers | HSTS, nosniff, HTTP/3 advertised |

Notes from staging: the droplet's `dmtc-platform` checkout is on `devel`
(restore scripts, TLS mode) and must return to `main` once those changes are
promoted; `.env.prod` has `TLS_MODE=internal` and must switch to `acme` at
cutover; the ui image must be built with `target: production` (now pinned).

Found 2026-09-18 while wiring ORCID: Caddy's production site block proxied to
`ui:80`, but Compose registers a service's own name as an alias on *every*
network it joins, so the development site's ui also answered to `ui` on
`dmtc-edge`, and Caddy (a member of both networks) resolved `ui` to the dev
site. Every www.dmtc-prod.org request was reaching the development stack. Fixed
by giving the production ui a `ui-prod` alias on its own network
(`docker-compose.prod.yml`) and pointing `caddy/sites/prod.caddy` at it; the
Caddy container also had to be recreated because its bind mount of `caddy/tls`
still referenced the directory inode from before the branch switch and showed
it empty. Both sites verified separately afterwards (`/api/orcid_sign_in`
returns each host's own callback base). ORCID client id and secret are now set
in `.env.prod` and `.env.devsite` on the droplet (one production client, both
callback URIs plus the legacy ESIP one registered).

ORCID sign-in and logout verified end to end on both sites 2026-09-18. Two
more API/UI defects surfaced and were fixed (uncommitted on the `devel`
branches; applied by hand on the droplet's `main`/`master` checkouts):

- `orcid_callback` rebuilt its redirect URI by replacing `request.host_url`
  (`http://host/`, trailing slash) with `FRONT_END_URL` (no slash), sending
  ORCID `https://www.dmtc-prod.orgapi/...` at token exchange and getting
  `invalid_grant`. It now uses `ORCID_REDIRECT_URL + "/" + origin`, exactly
  as `orcid_sign_in` does, and returns a 400/502 with ORCID's message instead
  of a 500. This was the underlying cause of the sign-in 500 on the UNM host.
- Logout failed with "Network Error": the UI called `/api/logout` without the
  trailing slash, Flask's 308 redirect was built as `http://` (nginx overwrote
  Caddy's `X-Forwarded-Proto` with its own `$scheme`), and the browser refused
  the scheme change. Fixed three ways: ProxyFix in the API (`x_proto`,
  `x_host`), nginx passing the upstream `X-Forwarded-Proto` through, and the
  UI calling `/api/logout/`.

Files modified on the droplet outside git (revert with `git checkout -- .`
once promoted): dmtc-platform `docker-compose.prod.yml`,
`caddy/sites/prod.caddy`; imls-dmt-api `dmtclearinghouse.py`; userinterface
`ui/nginx.conf`, `ui/src/services/auth.service.js`.

## Still to do before cutover

1. Delete orphaned droplet 601271964 in the DO console.
2. Add kbene@karlbenedict.com to the DO team and repoint the four alert emails.
3. ~~ORCID~~ Done 2026-09-18: one production client, three redirect URIs
   (prod, devel, legacy ESIP), credentials in both env files, sign-in and
   logout verified on both sites. Note for testing with a hosts-file override:
   NordVPN's tunnel extension resolves DNS itself and ignores `/etc/hosts`;
   disconnect it (or use Chrome's `--host-resolver-rules`) for the test.
4. Promote the uncommitted fixes above (dmtc-platform, imls-dmt-api,
   userinterface) devel -> testing -> main/master; then on the droplet
   `git checkout -- .` in each repo and `git pull`, and rebuild with
   `make prod-deploy` / `make devsite-deploy`.
5. **Reset both stacks to the source data before cutover.** The staged
   production stack and the dev site have been used for testing (workflow
   changes, edits), so before DNS moves restore both from the 2026-09-16
   export taken from the UNM host, or from a fresh export taken the same day
   if production has been edited since (compare `modification_date` maxima
   first). Files: `backup/dmtc-imls-20260916.sql.gz` and
   `backup/dmtc-solr-data-20260916.tgz` (also on the droplet under
   `~/dmtc-import/`). Commands, on the droplet:
   ```
   make prod-restore-db     DUMP=~/dmtc-import/dmtc-imls-YYYYMMDD.sql.gz
   make prod-restore-solr   TARBALL=~/dmtc-import/dmtc-solr-data-YYYYMMDD.tgz
   ./scripts/restore-db-dump.sh    devsite ~/dmtc-import/dmtc-imls-YYYYMMDD.sql.gz
   ./scripts/restore-solr-index.sh devsite ~/dmtc-import/dmtc-solr-data-YYYYMMDD.tgz
   ```
   `restore-db-dump.sh` replaces rows in the same tables; if test activity
   created new records, drop and recreate the `imls` database first so no
   test rows survive (`mysql -e 'DROP DATABASE imls; CREATE DATABASE imls'`
   inside the mysql container, then `init-mysql.sql`, then the restore).
6. Cutover: set `TLS_MODE=acme` in `.env.prod`, `make prod-up`; lower TTLs at
   Hover, then point A records for `dmtc-prod.org`, `www.dmtc-prod.org`,
   `dmtc-devel.org`, `www.dmtc-devel.org` at **134.199.249.40**; watch
   `make prod-logs` for certificate issuance; confirm the uptime checks and
   retarget the API check to `/api/health`.
7. Dev site is already running (`make devsite-up`); it is reset in step 5.
8. Run `make prod-backup` once by hand to create the Spaces bucket, then create
   a bucket-scoped key and delete the bootstrap key.
9. Ask ESIP for the legacy CNAME; enable `caddy/sites/legacy.caddy`.
