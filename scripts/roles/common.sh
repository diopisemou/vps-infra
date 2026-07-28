#!/usr/bin/env bash
# Base hardening + Docker install. Idempotent - safe to re-run.
#
# Firewall policy note: this box may already be running a PaaS whose admin UI is
# the ONLY way in (Coolify on 8000/6001/6002, Dokploy on 3000). Enabling ufw with
# a bare "allow 22,80,443" would risk cutting off that path, so we detect what is
# installed and keep its ports open. Override/extend with:
#   EXTRA_ALLOW_PORTS="9000 9443" bash common.sh
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "-- apt update/upgrade --"
apt-get update -y
apt-get upgrade -y

echo "-- packages --"
apt-get install -y \
  ufw fail2ban unattended-upgrades apt-listchanges \
  curl ca-certificates gnupg lsb-release jq

echo "-- unattended-upgrades --"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- SSH key first, before anything that could lock us out -------------------
echo "-- ensure our SSH key is authorized --"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIkVHZ1Pgd3J4DqMmcxIa7xrAXRhzNM4NSpQsaSK6hWj bachir-vps-2026-07"
grep -qxF "$KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo "-- tailscale (out-of-band access path; ISP blocks outbound :22 from home) --"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled
if tailscale status >/dev/null 2>&1; then
  echo "   tailscale already up as: $(tailscale ip -4 2>/dev/null | head -1)"
else
  echo "   !! tailscale installed but NOT logged in."
  echo "   !! Run 'tailscale up --hostname=$(hostname)' and open the printed URL."
fi

# --- Firewall ----------------------------------------------------------------
echo "-- firewall (ufw) --"
ALLOW_PORTS=(80 443)

if [[ -d /data/coolify ]]; then
  echo "   detected Coolify -> keeping 8000 (UI) + 6001/6002 (realtime/terminal) open"
  ALLOW_PORTS+=(8000 6001 6002)
fi
if [[ -d /etc/dokploy ]]; then
  echo "   detected Dokploy -> keeping 3000 (UI) open"
  ALLOW_PORTS+=(3000)
fi
for p in ${EXTRA_ALLOW_PORTS:-}; do
  echo "   EXTRA_ALLOW_PORTS -> $p"
  ALLOW_PORTS+=("$p")
done

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
# Trust the tailnet completely - that is our reliable way back in.
ufw allow in on tailscale0 comment 'tailnet' 2>/dev/null || true
for p in "${ALLOW_PORTS[@]}"; do
  ufw allow "${p}/tcp"
done
ufw --force enable
ufw status numbered

echo "-- fail2ban: default sshd jail --"
systemctl enable --now fail2ban

# --- Docker (before the deploy user, so the docker group exists) -------------
echo "-- docker --"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "-- non-root deploy user --"
if ! id -u deploy >/dev/null 2>&1; then
  useradd -m -s /bin/bash deploy
  echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
  chmod 440 /etc/sudoers.d/deploy
fi
usermod -aG sudo,docker deploy
mkdir -p /home/deploy/.ssh
cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

echo "-- sshd: disable password auth (key-only) --"
# Provider VNC/console login is unaffected by this - that stays as the fallback.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sshd -t && { systemctl reload sshd || systemctl reload ssh; }

echo "-- vps-infra state dir --"
mkdir -p /etc/vps-infra /opt/vps-infra

echo "common.sh done on $(hostname) at $(date -Is)"
