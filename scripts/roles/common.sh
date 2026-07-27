#!/usr/bin/env bash
# Base hardening + Docker install. Idempotent - safe to re-run.
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

echo "-- firewall (ufw): allow SSH, HTTP, HTTPS only --"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "-- fail2ban: default sshd jail --"
systemctl enable --now fail2ban

echo "-- non-root deploy user --"
if ! id -u deploy >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,docker deploy || useradd -m -s /bin/bash -G sudo deploy
  mkdir -p /home/deploy/.ssh
  cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys 2>/dev/null || true
  chown -R deploy:deploy /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  chmod 600 /home/deploy/.ssh/authorized_keys 2>/dev/null || true
  echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
fi

echo "-- ensure our SSH key is authorized before locking password auth --"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIkVHZ1Pgd3J4DqMmcxIa7xrAXRhzNM4NSpQsaSK6hWj bachir-vps-2026-07"
grep -qxF "$KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo "-- sshd: disable password auth (key-only) --"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload sshd || systemctl reload ssh || true

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
usermod -aG docker deploy 2>/dev/null || true

echo "-- vps-infra state dir --"
mkdir -p /etc/vps-infra /opt/vps-infra

echo "common.sh done on $(hostname) at $(date -Is)"
