#!/usr/bin/env bash
# DMTC development environment setup script
# Ubuntu 22.04 or 24.04 — AMD64 or ARM64
#
# Two-phase design so it can be called by Lima's provision system (which runs
# system and user phases separately) or run manually on a Linux server:
#
#   Phases:
#     system  — install Docker, Node.js 20, dev tools (requires root)
#     user    — install Claude Code, configure docker group, print next steps
#     all     — run system then user (for a fresh single-user VM as root)
#
#   Manual usage on an existing Linux server or cloud VM:
#     sudo bash setup.sh system
#     bash setup.sh user
#
#   As cloud-init user-data (paste into AWS/GCP/DO user-data):
#     see dev-vm/cloud-init.yaml in this repository
#
#   Invoked by Lima's provision section in dev-vm/lima.yaml.
#
# After both phases complete, clone the repos and follow the printed instructions.

set -euo pipefail

PHASE="${1:-all}"
NODE_MAJOR=20

# ── Utility ───────────────────────────────────────────────────────────────────
log() { echo "  [setup] $*"; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "ERROR: 'system' phase must run as root (sudo bash setup.sh system)" >&2
        exit 1
    fi
}

# ── System phase (root) ───────────────────────────────────────────────────────
phase_system() {
    require_root
    log "Updating package index..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git make wget unzip jq openssh-client mysql-client

    # Docker Engine
    log "Installing Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') installed."

    # Node.js 20 LTS
    log "Installing Node.js ${NODE_MAJOR} LTS..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
    log "Node $(node --version) / npm $(npm --version) installed."
}

# ── User phase (non-root) ─────────────────────────────────────────────────────
phase_user() {
    # Add current user to docker group so docker commands don't need sudo.
    # The group change takes effect on next login / new shell.
    if ! groups "$USER" | grep -q docker; then
        log "Adding $USER to docker group..."
        sudo usermod -aG docker "$USER"
    fi

    # Configure npm to use a user-local prefix so global installs don't need sudo
    mkdir -p ~/.npm-global
    npm config set prefix ~/.npm-global
    export PATH="$HOME/.npm-global/bin:$PATH"
    grep -qxF 'export PATH="$HOME/.npm-global/bin:$PATH"' ~/.bashrc \
        || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc

    # Claude Code CLI
    log "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    log "Claude Code $(claude --version 2>/dev/null || echo '(installed)') ready."

    # Friendly reminder for Git identity (no-op if already set)
    if [[ -z "$(git config --global user.email 2>/dev/null)" ]]; then
        log "Git identity not set — configure it after setup:"
        log "  git config --global user.email 'you@example.com'"
        log "  git config --global user.name  'Your Name'"
    fi

    cat <<'BANNER'

════════════════════════════════════════════════════════════════════════
DMTC development environment ready.

Next steps
──────────
1. Start a new shell (or run: newgrp docker) so the docker group is active.

2. Clone the three repos into a working directory:
     mkdir -p ~/Repos/DMTC && cd ~/Repos/DMTC
     git clone https://github.com/imls-dmt/dmtc-platform.git
     git clone https://github.com/imls-dmt/imls-dmt-api.git
     git clone https://github.com/imls-dmt/userinterface.git
     cd dmtc-platform
     git checkout devel

3. Create and fill in the dev environment file:
     cp .env.dev.example .env.dev
     # Edit .env.dev — at minimum set FLASK_SECRET_KEY and MYSQL passwords

4. Start the dev stack:
     make dev-up

5. Authenticate Claude Code (pick one):
     export ANTHROPIC_API_KEY=sk-ant-...   # add to ~/.bashrc / ~/.zshrc
     # or: claude auth login               # browser-based login

   Then open a Claude Code session from the dmtc-platform directory:
     claude

Dev stack ports (forwarded to host if using Lima):
  http://localhost:8082  — Vue hot-reload UI
  http://localhost:5001  — Flask API (direct)
  localhost:8984         — Solr admin UI
  localhost:3307         — MySQL
════════════════════════════════════════════════════════════════════════
BANNER
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$PHASE" in
    system) phase_system ;;
    user)   phase_user   ;;
    all)
        phase_system
        # Re-run user phase as the invoking non-root user if available,
        # otherwise as the current user (which is root for 'all' mode).
        REAL_USER="${SUDO_USER:-${USER}}"
        if [[ "$REAL_USER" == "root" ]]; then
            phase_user
        else
            sudo -u "$REAL_USER" bash "$0" user
        fi
        ;;
    *)
        echo "Usage: bash setup.sh [system|user|all]" >&2
        exit 1
        ;;
esac
