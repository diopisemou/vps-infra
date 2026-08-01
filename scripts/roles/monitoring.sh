#!/usr/bin/env bash
# Uptime Kuma (status page + alerting) watching every other host.
#
# Exposure note, because it is easy to get wrong: UFW does NOT filter published
# Docker ports. Docker inserts its own rules ahead of ufw's chain, so
# `-p 3001:3001` is reachable from the internet no matter what ufw says, and
# deleting the ufw rule changes nothing. The only thing that actually restricts it
# is the bind address in the port publish. So when a tailnet address exists we
# publish on it exclusively, which keeps the admin UI and its login off the
# public internet entirely.
#
# Set KUMA_BIND=public to deliberately publish on all interfaces instead.
set -euo pipefail

mkdir -p /opt/monitoring/uptime-kuma-data

TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
if [[ "${KUMA_BIND:-}" == "public" || -z "$TS_IP" ]]; then
  PUBLISH="3001:3001"
  BIND_DESC="ALL interfaces (public)"
  [[ -z "$TS_IP" ]] && echo "!! no tailnet address yet - publishing publicly. Re-run after 'tailscale up' to lock it down." >&2
else
  PUBLISH="${TS_IP}:3001:3001"
  BIND_DESC="tailnet only (${TS_IP})"
fi

current="$(docker inspect uptime-kuma --format '{{json .HostConfig.PortBindings}}' 2>/dev/null || echo '')"
want_host="${PUBLISH%:3001}"; want_host="${want_host%:3001}"
[[ "$PUBLISH" == "3001:3001" ]] && want_host=""

recreate=0
if ! docker inspect uptime-kuma >/dev/null 2>&1; then
  recreate=1
elif ! echo "$current" | grep -q "\"HostIp\":\"${want_host}\""; then
  echo "-- port binding changed (want ${BIND_DESC}), recreating container --"
  echo "   data lives in the /opt/monitoring/uptime-kuma-data bind mount, so nothing is lost"
  docker rm -f uptime-kuma >/dev/null
  recreate=1
else
  echo "uptime-kuma already published on ${BIND_DESC}, ensuring it is running."
  docker start uptime-kuma >/dev/null 2>&1 || true
fi

if (( recreate )); then
  docker run -d \
    --name uptime-kuma \
    --restart unless-stopped \
    -p "$PUBLISH" \
    -v /opt/monitoring/uptime-kuma-data:/app/data \
    louislam/uptime-kuma:1
fi

# Harmless when bound to the tailnet, and required when bound publicly.
ufw allow 3001/tcp >/dev/null 2>&1 || true

echo "monitoring.sh done. Uptime Kuma published on: ${BIND_DESC}"
if [[ -n "$TS_IP" && "${KUMA_BIND:-}" != "public" ]]; then
  echo "  UI:  http://${TS_IP}:3001   (or http://monitoring:3001 with MagicDNS)"
  echo "  Reachable only from devices on your tailnet."
else
  IP="$(curl -4 -fsS --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
  echo "  UI:  http://${IP}:3001"
fi
