SHELL := /bin/bash
.DEFAULT_GOAL := help

# ── Compose command helpers ────────────────────────────────────────────────────
DEV_COMPOSE  := docker compose -p dmtc-dev  -f docker-compose.yml -f docker-compose.dev.yml  --env-file .env.dev
TEST_COMPOSE := docker compose -p dmtc-test -f docker-compose.yml -f docker-compose.test.yml --env-file .env.test

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

scripts/.env.prod-sync:
	@echo "ERROR: scripts/.env.prod-sync not found. Copy scripts/.env.prod-sync.example and fill in values:" >&2
	@echo "  cp scripts/.env.prod-sync.example scripts/.env.prod-sync" >&2
	@exit 1

# ── Help ──────────────────────────────────────────────────────────────────────
.PHONY: help
help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
