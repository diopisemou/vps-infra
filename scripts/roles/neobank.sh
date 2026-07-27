#!/usr/bin/env bash
# Isolated neobank stack: Kong, Hydra, Logto, Steel, api/auth. No PaaS, deliberately.
set -euo pipefail
mkdir -p /opt/neobank
cp -n "$(dirname "${BASH_SOURCE[0]}")/../../compose/neobank-compose.yml" /opt/neobank/docker-compose.yml 2>/dev/null || true

echo "-- tighter firewall for neobank box: only 22/80/443, nothing else --"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "neobank.sh done. Fill in /opt/neobank/docker-compose.yml with real service configs, then:"
echo "  cd /opt/neobank && docker compose up -d"
echo "Reminder: this box stays isolated from the shared PaaS hosts by design (compliance boundary)."
