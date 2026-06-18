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
dev-reindex: .env.dev  ## Trigger a full Solr reindex on the dev stack
	@./scripts/reindex.sh "http://localhost:$$(grep DEV_UI_PORT .env.dev | cut -d= -f2)" "$(DMTC_ADMIN_USER)" "$(DMTC_ADMIN_PASS)"

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
test-reindex: .env.test  ## Trigger a full Solr reindex on the test stack
	@./scripts/reindex.sh "http://localhost:$$(grep TEST_UI_PORT .env.test | cut -d= -f2)" "$(DMTC_ADMIN_USER)" "$(DMTC_ADMIN_PASS)"

# ── Database sync ─────────────────────────────────────────────────────────────
.PHONY: sync-db-dev
sync-db-dev: .env.dev scripts/.env.prod-sync  ## Sync production DB snapshot into dev stack
	@echo "Syncing production DB → dev stack..."
	@./scripts/sync-db-from-prod.sh dev

.PHONY: sync-db-test
sync-db-test: .env.test scripts/.env.prod-sync  ## Sync production DB snapshot into test stack
	@echo "Syncing production DB → test stack..."
	@./scripts/sync-db-from-prod.sh test

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
vm-ssh-config:  ## Print SSH config snippet for VS Code Remote-SSH / manual SSH
	@limactl show-ssh --format=config dmtc

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
