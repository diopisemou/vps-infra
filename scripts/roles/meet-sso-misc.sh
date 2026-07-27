#!/usr/bin/env bash
# Dokploy install, then deploy Keycloak + Jitsi Meet as Dokploy-managed compose apps.
set -euo pipefail
if [[ -d /etc/dokploy ]]; then
  echo "Dokploy already appears installed, skipping installer."
else
  curl -sSL https://dokploy.com/install.sh | sh
fi
mkdir -p /opt/vps-infra/meet-sso
cp -n "$(dirname "${BASH_SOURCE[0]}")/../../backup/../compose/keycloak-compose.yml" /opt/vps-infra/meet-sso/ 2>/dev/null || true
cp -n "$(dirname "${BASH_SOURCE[0]}")/../../compose/jitsi-compose.yml" /opt/vps-infra/meet-sso/ 2>/dev/null || true
echo "meet-sso-misc.sh done. Log into Dokploy at https://$(curl -s ifconfig.me):3000, then import"
echo "  /opt/vps-infra/meet-sso/keycloak-compose.yml (realm: AlMinhaaj)"
echo "  /opt/vps-infra/meet-sso/jitsi-compose.yml"
echo "as two applications and point DNS (keycloak.alminhaaj.info, meet.alminhaaj.info) at this box's IP."
