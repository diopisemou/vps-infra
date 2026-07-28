#!/usr/bin/env bash
# Uptime Kuma (status page + alerting) watching every other host.
set -euo pipefail
mkdir -p /opt/monitoring/uptime-kuma-data

# Idempotent: a bare 'docker run --name' fails on re-run with a name conflict.
if docker inspect uptime-kuma >/dev/null 2>&1; then
  echo "uptime-kuma container already exists, ensuring it is running."
  docker start uptime-kuma >/dev/null
else
  docker run -d \
    --name uptime-kuma \
    --restart unless-stopped \
    -p 3001:3001 \
    -v /opt/monitoring/uptime-kuma-data:/app/data \
    louislam/uptime-kuma:1
fi

# common.sh's ufw denies incoming by default, so 3001 needs opening explicitly.
ufw allow 3001/tcp || true

IP="$(curl -4 -fsS --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
echo "monitoring.sh done. Uptime Kuma is on port 3001 - open http://${IP}:3001 to finish setup"
echo "and add monitors for: 169.58.77.127 (main-host), 169.58.79.167 (neobank), 2.28.13.102 (meet-sso-misc)."
