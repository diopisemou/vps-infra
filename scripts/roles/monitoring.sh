#!/usr/bin/env bash
# Uptime Kuma (status page + alerting) watching every other host.
set -euo pipefail
mkdir -p /opt/monitoring/uptime-kuma-data
docker run -d \
  --name uptime-kuma \
  --restart unless-stopped \
  -p 3001:3001 \
  -v /opt/monitoring/uptime-kuma-data:/app/data \
  louislam/uptime-kuma:1

echo "monitoring.sh done. Uptime Kuma is on port 3001 - open http://$(curl -s ifconfig.me):3001 to finish setup"
echo "and add monitors for: 169.58.77.127 (main-host), 169.58.79.167 (neobank), 2.28.13.102 (meet-sso-misc)."
