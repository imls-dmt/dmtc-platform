#!/usr/bin/env bash
# Provision a DMTC production host without cloud-init (or after cloud-init
# failed). Idempotent: safe to re-run. Mirrors dev-vm/cloud-init-prod.yaml.
#
#   scp dev-vm/setup-prod.sh root@<ip>:/root/ && ssh root@<ip> bash /root/setup-prod.sh
#
# Creates the dmtc deploy user, installs Docker Engine + compose, rclone, the
# DigitalOcean metrics agent, unattended-upgrades, fail2ban, ufw rules, a 2 GB
# swap file, clones the three repositories into /opt/dmtc, creates the shared
# dmtc-edge network and installs the nightly backup cron. Does NOT start the
# stack: write /opt/dmtc/dmtc-platform/.env.prod first, then 'make prod-up'.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

AUTHORIZED_KEYS='
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDa7g7ZyLoGdeJZJtF03o0ha76NNERd6DP/Bro+jzOZbEL9NZufsyYFcD94DWncXQcMMX8jNeoD/XI8GmqPLzpP7VjzMWOCphV/Ej8jx7JTr7/biJekqnWBbss/f1MyXX9Nq9S9ULA2NWQRmDt1Wu4YZx2/HcP4NR0tzUcFquRI06kvQmwUhoYpRE3i1XGx4DbKlsls5NFF1Dm3YJCK5UWqVa3XsiyK5vu4Mnk+aKkQYOsHiqr8FLlusPAOoZiT5z4HWCueBpcreGYPwGY85MVgYRgGq0DK+KZ3syEIJQv3On2eZ1vD9cUnE3sjmSNiC4iZLoz5ynPkCbF7T893aLOGHEBeCOH4MPcLuwdnbBnhy5EacNp17SjBProCiaGYXocG6TyMyv7ICBZhEPgLuQDpG6GTFPIGQd19z3c0HTSG1nj/Az8OFr+WyXGfLj79u4F8ZJcr0MmGjW3b+HzgnRSBzkyvM3OOTFeRD6jhjE79UjuijAZuVCs9+HNxWeqAO26sNV2/i8bbbICD7dDhrjkhzkyc2q2oiOlfRxeLus70rrWosLFBZNzA5w05YkVgf5Kssh9YgENYWrE4yZq3K59kfc5o+DTXrexqVKqLrd1rARRJtjOG5QV/r0W+nN9/jl8L9HrnPLLKsZ7Qb14LYRsVIqZh7EJVZ9AUtPHSVLS8nQ== kbene@karls-mbp.unm.edu
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBDrqzxxBy3Xq6EwLZhsOZ+WfVMDc9oBFZCaIKuaErL9 kbene@unm.edu
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDcUPsbgbf/S/2pQ/H6Pj6fViRBlVPRj/fbCVAwDZ8cL3NVwbWJ6q4nf55PkNJPr0z9hegcQOF+DM3FhqYroAUJqUuRfjYSA0bHSoZMs1g0ZbCIxYJlwjdNC12IMggQQKMp7WVzYNLQHJjOmPZpLXgCRL3Kx4OCl8Ho5nWZdIDe5de+yeg7KXXhOa5MSRnzhgZSh6ltC1jvRZHVYF1uMTuAPEqAxFXNtuq+bm0djoz+PXBQPJosAJY/Ml8wig4u6JVTZUJ+YjejADBWmpiYoSwyvy+R6g43D53C9XWmuBNQkX9twrdY+oFcxQuztitKcG6pwmXR0BAZokzKh8cyiAInaG8JMmUdTEwQhXKbgJfnupw1fVgQ9wWTDchZOaJKSrUaJ4NLVun3c6ASQYjBprXPSF1aWPIh/0c4BkAtPow4O1wafobSyYLDdoGSra2JxOyc9Hvu/0s4hKpiH4Ovl0qHs30gChBrJwkcuHr2yoA4iIed7A416Tg/Ez0lfB6h8k0= kbene@Karls-iMac.local
'

echo "== packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git make jq rclone mysql-client unattended-upgrades fail2ban ufw > /dev/null

echo "== deploy user dmtc"
id dmtc &>/dev/null || useradd -m -s /bin/bash -G sudo dmtc
install -d -m 700 -o dmtc -g dmtc /home/dmtc/.ssh
printf '%s\n' "$AUTHORIZED_KEYS" | sed '/^$/d' > /home/dmtc/.ssh/authorized_keys
chown dmtc:dmtc /home/dmtc/.ssh/authorized_keys && chmod 600 /home/dmtc/.ssh/authorized_keys
echo 'dmtc ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-dmtc && chmod 440 /etc/sudoers.d/90-dmtc

echo "== docker engine"
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null
fi
systemctl enable --now docker
usermod -aG docker dmtc

echo "== digitalocean metrics agent"
systemctl is-active --quiet do-agent 2>/dev/null || curl -sSL https://repos.insights.digitalocean.com/install.sh | bash > /dev/null

echo "== swap (2G)"
if ! swapon --show | grep -q '^/swapfile'; then
  [[ -f /swapfile ]] || fallocate -l 2G /swapfile
  chmod 600 /swapfile; mkswap /swapfile > /dev/null; swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "== firewall (ufw, behind the DO cloud firewall)"
ufw default deny incoming > /dev/null; ufw default allow outgoing > /dev/null
ufw allow OpenSSH > /dev/null; ufw allow 80/tcp > /dev/null; ufw allow 443/tcp > /dev/null; ufw allow 443/udp > /dev/null
ufw --force enable > /dev/null

echo "== unattended upgrades, fail2ban"
cat > /etc/apt/apt.conf.d/50unattended-upgrades-dmtc <<'CONF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
CONF
systemctl enable --now unattended-upgrades fail2ban > /dev/null 2>&1 || true

echo "== repositories under /opt/dmtc"
install -d -o dmtc -g dmtc /opt/dmtc
clone() { local repo=$1 branch=$2 extra=${3:-}; if [[ -d /opt/dmtc/$repo/.git ]]; then sudo -u dmtc git -C /opt/dmtc/$repo pull -q --ff-only; else sudo -u dmtc git clone -q --branch "$branch" $extra https://github.com/imls-dmt/$repo.git /opt/dmtc/$repo; fi; }
clone imls-dmt-api master
clone userinterface master --recurse-submodules
clone dmtc-platform main

echo "== shared docker network"
docker network inspect dmtc-edge > /dev/null 2>&1 || docker network create dmtc-edge > /dev/null

echo "== nightly backup cron"
cat > /etc/cron.d/dmtc-backup <<'CRON'
# Nightly at 03:15 UTC: Solr -> MySQL sync, mysqldump, upload to Spaces.
15 3 * * * dmtc cd /opt/dmtc/dmtc-platform && ./scripts/backup-to-spaces.sh prod >> /var/log/dmtc-backup.log 2>&1
CRON
touch /var/log/dmtc-backup.log && chown dmtc:dmtc /var/log/dmtc-backup.log
cat > /etc/logrotate.d/dmtc-backup <<'ROT'
/var/log/dmtc-backup.log { weekly rotate 8 compress missingok notifempty }
ROT

echo "== done"
echo "Next: write /opt/dmtc/dmtc-platform/.env.prod, then as dmtc: cd /opt/dmtc/dmtc-platform && make prod-up"
