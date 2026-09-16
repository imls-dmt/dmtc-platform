# dmtc-platform

Orchestration for the Data Management Training Clearinghouse (DMTC): Docker
Compose stacks, provisioning, backups and operations for the
[imls-dmt-api](https://github.com/imls-dmt/imls-dmt-api) (Flask + Solr + MySQL)
and [userinterface](https://github.com/imls-dmt/userinterface) (Vue 3) repositories,
which are expected to be checked out as siblings of this directory.

| Stack | Command | Purpose |
|---|---|---|
| dev | `make dev-up` | Flask dev server and Vue hot-reload, source mounted, ports on localhost |
| test | `make test-up` | Production-like builds on alternate ports for pre-merge checks |
| prod | `make prod-up` | Production on the DigitalOcean droplet, Caddy TLS in front |
| devsite | `make devsite-up` | Public dmtc-devel.org stack on the same droplet, separate data |

`make help` lists every target. Each stack reads its own `.env.<stack>` file;
copy the matching `.env.<stack>.example` and fill in values (never committed).

- `docs/digitalocean-migration.md`: hosting architecture, migration plan,
  monitoring, ORCID review.
- `dev-vm/`: Lima VM for macOS, cloud-init for dev and production hosts.
- `solr/configsets/`: canonical Solr 8.11.1 configsets extracted from production.
- `scripts/`: Solr/MySQL initialization, seeding, reindex, production DB sync,
  Spaces backups.

Branches: `devel` (free push) -> `testing` (PR + review) -> `main` (PR + review).
