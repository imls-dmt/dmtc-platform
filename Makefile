SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Compose command helpers ────────────────────────────────────────────────────
DEV_COMPOSE  := docker compose -p dmtc-dev  -f docker-compose.yml -f docker-compose.dev.yml  --env-file .env.dev
TEST_COMPOSE := docker compose -p dmtc-test -f docker-compose.yml -f docker-compose.test.yml --env-file .env.test
PROD_COMPOSE := docker compose -p dmtc-prod -f docker-compose.yml -f docker-compose.prod.yml --env-file .env.prod
DEVSITE_COMPOSE := docker compose -p dmtc-devsite -f docker-compose.yml -f docker-compose.devsite.yml --env-file .env.devsite

# ── Dev stack ─────────────────────────────────────────────────────────────────
.PHONY: dev-up
dev-up: .env.dev  ## Start the dev stack (Flask dev server + Vue hot-reload)
	$(DEV_COMPOSE) up

.PHONY: dev-up-d
dev-up-d: .env.dev  ## Start the dev stack in detached mode
	$(DEV_COMPOSE) up -d

.PHONY: dev-down
dev-down:  ## Stop and remove dev stack containers (preserves volumes)
	$(DEV_COMPOSE) down

.PHONY: dev-build
dev-build: .env.dev  ## Rebuild dev stack images without cache
	$(DEV_COMPOSE) build --no-cache

.PHONY: dev-logs
dev-logs:  ## Stream logs from the dev stack
	$(DEV_COMPOSE) logs -f

.PHONY: dev-reindex
dev-reindex: .env.dev  ## Trigger a full Solr reindex on the dev stack (needs admin login)
	@./scripts/reindex.sh "http://localhost:$$(grep DEV_UI_PORT .env.dev | cut -d= -f2)" "$(DMTC_ADMIN_USER)" "$(DMTC_ADMIN_PASS)"

.PHONY: seed-solr-dev
seed-solr-dev: .env.dev  ## Bootstrap-seed dev Solr from MySQL blobs (no auth; run after sync-db-dev)
	@./scripts/seed-solr.sh dev

.PHONY: backup-solr-dev
backup-solr-dev: .env.dev  ## Back up dev Solr-primary cores (questions/surveys/answers/...) into MySQL
	@./scripts/sync-solr-to-mysql.sh dev

# ── Test stack ────────────────────────────────────────────────────────────────
.PHONY: test-up
test-up: .env.test  ## Start the test stack (production-like builds)
	$(TEST_COMPOSE) up

.PHONY: test-up-d
test-up-d: .env.test  ## Start the test stack in detached mode
	$(TEST_COMPOSE) up -d

.PHONY: test-down
test-down:  ## Stop and remove test stack containers (preserves volumes)
	$(TEST_COMPOSE) down

.PHONY: test-build
test-build: .env.test  ## Rebuild test stack images without cache
	$(TEST_COMPOSE) build --no-cache

.PHONY: test-logs
test-logs:  ## Stream logs from the test stack
	$(TEST_COMPOSE) logs -f

.PHONY: test-reindex
test-reindex: .env.test  ## Trigger a full Solr reindex on the test stack (needs admin login)
	@./scripts/reindex.sh "http://localhost:$$(grep TEST_UI_PORT .env.test | cut -d= -f2)" "$(DMTC_ADMIN_USER)" "$(DMTC_ADMIN_PASS)"

.PHONY: seed-solr-test
seed-solr-test: .env.test  ## Bootstrap-seed test Solr from MySQL blobs (no auth; run after sync-db-test)
	@./scripts/seed-solr.sh test

.PHONY: backup-solr-test
backup-solr-test: .env.test  ## Back up test Solr-primary cores into MySQL
	@./scripts/sync-solr-to-mysql.sh test

# ── Production stack (droplet) ────────────────────────────────────────────────
.PHONY: prod-up
prod-up: .env.prod  ## Start/refresh the production stack (Caddy TLS + ui + api + solr + mysql), detached
	$(PROD_COMPOSE) up -d --remove-orphans

.PHONY: prod-down
prod-down:  ## Stop production containers (volumes and certificates preserved)
	$(PROD_COMPOSE) down

.PHONY: prod-build
prod-build: .env.prod  ## Rebuild production images (ui and api) from the checked-out sources
	$(PROD_COMPOSE) build --pull

.PHONY: prod-deploy
prod-deploy: .env.prod  ## Pull master/main in all three repos, rebuild, restart, and wait for /api/health
	@set -e; for r in imls-dmt-api userinterface dmtc-platform; do \
	  echo "== $$r"; git -C "$(CURDIR)/../$$r" pull --ff-only; done
	git -C "$(CURDIR)/../userinterface" submodule update --init --recursive
	$(PROD_COMPOSE) build --pull
	$(PROD_COMPOSE) up -d --remove-orphans
	@./scripts/wait-for-health.sh "https://$$(grep ^PROD_HOST .env.prod | cut -d= -f2)/api/health"

.PHONY: prod-reload
prod-reload:  ## Reload Caddy after editing caddy/Caddyfile or caddy/sites/*.caddy
	$(PROD_COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile

.PHONY: prod-logs
prod-logs:  ## Stream logs from the production stack
	$(PROD_COMPOSE) logs -f --tail=200

.PHONY: prod-status
prod-status: .env.prod  ## Container status plus the API health report
	$(PROD_COMPOSE) ps
	@curl -fsS "https://$$(grep ^PROD_HOST .env.prod | cut -d= -f2)/api/health" || true; echo

.PHONY: prod-backup
prod-backup: .env.prod  ## Run the nightly backup now (Solr->MySQL sync, mysqldump, upload to Spaces)
	@./scripts/backup-to-spaces.sh prod

.PHONY: prod-restore-db
prod-restore-db: .env.prod  ## Import a production MySQL dump: make prod-restore-db DUMP=path/to/dmtc-imls-YYYYMMDD.sql.gz
	@./scripts/restore-db-dump.sh prod "$(DUMP)"

.PHONY: prod-restore-solr
prod-restore-solr: .env.prod  ## Restore Solr index data from a /var/solr/data tarball: make prod-restore-solr TARBALL=path/to/dmtc-solr-data-YYYYMMDD.tgz
	@./scripts/restore-solr-index.sh prod "$(TARBALL)"

.PHONY: prod-reindex
prod-reindex: .env.prod  ## Trigger a full Solr reindex on production (needs admin login)
	@./scripts/reindex.sh "https://$$(grep ^PROD_HOST .env.prod | cut -d= -f2)" "$(DMTC_ADMIN_USER)" "$(DMTC_ADMIN_PASS)"

# ── Development site (public dmtc-devel.org, same droplet) ────────────────────
.PHONY: devsite-up
devsite-up: .env.devsite  ## Start/refresh the public development site (served by the prod Caddy)
	$(DEVSITE_COMPOSE) up -d --remove-orphans

.PHONY: devsite-down
devsite-down:  ## Stop the development-site containers (volumes preserved)
	$(DEVSITE_COMPOSE) down

.PHONY: devsite-build
devsite-build: .env.devsite  ## Rebuild development-site images from the checked-out sources
	$(DEVSITE_COMPOSE) build --pull

.PHONY: devsite-logs
devsite-logs:  ## Stream logs from the development site
	$(DEVSITE_COMPOSE) logs -f --tail=200

.PHONY: devsite-backup
devsite-backup: .env.devsite  ## Back up the development-site database to Spaces
	@./scripts/backup-to-spaces.sh devsite

# ── Database sync ─────────────────────────────────────────────────────────────
.PHONY: sync-db-dev
sync-db-dev: .env.dev scripts/.env.prod-sync  ## Sync production DB snapshot into dev stack
	@echo "Syncing production DB → dev stack..."
	@./scripts/sync-db-from-prod.sh dev

.PHONY: sync-db-test
sync-db-test: .env.test scripts/.env.prod-sync  ## Sync production DB snapshot into test stack
	@echo "Syncing production DB → test stack..."
	@./scripts/sync-db-from-prod.sh test

# ── Backups ───────────────────────────────────────────────────────────────────
.PHONY: backup-memory
backup-memory:  ## Tarball the Claude memory dir off to DEST (default $HOME) for ephemeral-VM safety
	@DMTC_DIR=$$(cd "$(CURDIR)/.." && pwd); \
	SLUG=$$(printf '%s' "$$DMTC_DIR" | sed 's/[^a-zA-Z0-9]/-/g'); \
	MEMDIR="$$HOME/.claude/projects/$$SLUG/memory"; \
	if [ ! -d "$$MEMDIR" ]; then \
	  echo "Derived path $$MEMDIR not found; falling back to most-populated *Repos-DMTC memory dir." >&2; \
	  MEMDIR=$$(for d in $$HOME/.claude/projects/*Repos-DMTC/memory; do [ -d "$$d" ] && printf '%s %s\n' "$$(ls -1 "$$d" | wc -l)" "$$d"; done | sort -rn | head -1 | cut -d' ' -f2-); \
	fi; \
	if [ -z "$$MEMDIR" ] || [ ! -d "$$MEMDIR" ]; then echo "ERROR: Claude memory dir not found" >&2; exit 1; fi; \
	DEST=$${DEST:-$$HOME}; \
	OUT="$$DEST/dmtc-claude-memory-$$(date +%Y%m%d).tgz"; \
	tar czf "$$OUT" -C "$$(dirname "$$MEMDIR")" memory; \
	echo "Backed up $$MEMDIR ($$(ls -1 "$$MEMDIR" | wc -l | tr -d ' ') files)"; \
	echo "  -> $$OUT  ($$(du -h "$$OUT" | cut -f1))"; \
	echo "  copy off-VM, e.g.:  scp <vm>:$$OUT ."

# ── Lima VM (macOS only) ──────────────────────────────────────────────────────
.PHONY: vm-start
vm-start:  ## Create and start the Lima dev VM (runs provisioning on first start)
	limactl start --name=dmtc dev-vm/lima.yaml

.PHONY: vm-shell
vm-shell:  ## Open a shell inside the Lima VM
	limactl shell dmtc

.PHONY: vm-stop
vm-stop:  ## Stop the Lima VM (data preserved)
	limactl stop dmtc

.PHONY: vm-ssh-config
vm-ssh-config:  ## Print SSH command for connecting to the VM (VS Code Remote-SSH / manual SSH)
	@echo "ssh -F $$HOME/.lima/dmtc/ssh.config lima-dmtc"

.PHONY: vm-status
vm-status:  ## Show Lima VM status
	limactl list dmtc

# ── Env file guards ───────────────────────────────────────────────────────────
.env.dev:
	@echo "ERROR: .env.dev not found. Copy .env.dev.example and fill in values:" >&2
	@echo "  cp .env.dev.example .env.dev" >&2
	@exit 1

.env.test:
	@echo "ERROR: .env.test not found. Copy .env.test.example and fill in values:" >&2
	@echo "  cp .env.test.example .env.test" >&2
	@exit 1

.env.prod:
	@echo "ERROR: .env.prod not found. Copy .env.prod.example and fill in values:" >&2
	@echo "  cp .env.prod.example .env.prod" >&2
	@exit 1

.env.devsite:
	@echo "ERROR: .env.devsite not found. Copy .env.devsite.example and fill in values:" >&2
	@echo "  cp .env.devsite.example .env.devsite" >&2
	@exit 1

scripts/.env.prod-sync:
	@echo "ERROR: scripts/.env.prod-sync not found. Copy scripts/.env.prod-sync.example and fill in values:" >&2
	@echo "  cp scripts/.env.prod-sync.example scripts/.env.prod-sync" >&2
	@exit 1

# ── Help ──────────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
