#!/usr/bin/env bash
# Dokploy install, then stage Keycloak + Jitsi Meet compose files for import.
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/diopisemou/vps-infra/main}"

if [[ -d /etc/dokploy ]]; then
  echo "Dokploy already appears installed, skipping installer."
else
  curl -sSL https://dokploy.com/install.sh | sh
fi

mkdir -p /opt/vps-infra/meet-sso
for f in keycloak-compose.yml jitsi-compose.yml; do
  if [[ -f "/opt/vps-infra/meet-sso/$f" ]]; then
    echo "   $f already staged, leaving it alone"
  else
    curl -fsSL "$REPO_RAW_BASE/compose/$f" -o "/opt/vps-infra/meet-sso/$f"
    echo "   staged $f"
  fi
done

IP="$(curl -fsS --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
echo "meet-sso-misc.sh done. Log into Dokploy at http://${IP}:3000, then import"
echo "  /opt/vps-infra/meet-sso/keycloak-compose.yml (realm: AlMinhaaj)"
echo "  /opt/vps-infra/meet-sso/jitsi-compose.yml"
echo "as two applications and point DNS (keycloak.alminhaaj.info, meet.alminhaaj.info) at this box's IP."
