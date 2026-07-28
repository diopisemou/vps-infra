#!/usr/bin/env bash
# Isolated neobank stack: Kong, Hydra, Logto, Steel, api/auth. No PaaS, deliberately.
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/diopisemou/vps-infra/main}"

mkdir -p /opt/neobank
if [[ ! -f /opt/neobank/docker-compose.yml ]]; then
  curl -fsSL "$REPO_RAW_BASE/compose/neobank-compose.yml" -o /opt/neobank/docker-compose.yml
  echo "   fetched compose template -> /opt/neobank/docker-compose.yml"
else
  echo "   /opt/neobank/docker-compose.yml already exists, leaving it alone"
fi

# This box is deliberately stricter than the others: no PaaS admin UI to keep open,
# so nothing beyond SSH/HTTP/HTTPS is exposed. We do NOT 'ufw reset' here - that
# would drop the tailnet rule common.sh just added, which is our way back in.
echo "-- tighter firewall for neobank box --"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow in on tailscale0 comment 'tailnet' 2>/dev/null || true
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status numbered

echo "neobank.sh done. Fill in /opt/neobank/docker-compose.yml with real service configs, then:"
echo "  cd /opt/neobank && docker compose up -d"
echo "Reminder: this box stays isolated from the shared PaaS hosts by design (compliance boundary)."
