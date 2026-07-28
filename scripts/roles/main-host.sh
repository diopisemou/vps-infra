#!/usr/bin/env bash
# Coolify install for the main app host.
set -euo pipefail
if [[ -d /data/coolify ]]; then
  echo "Coolify already appears installed at /data/coolify, skipping installer."
else
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi
# -4: without it ifconfig.me may answer with the IPv6 address, which produces a
# malformed URL when a :port is appended to an unbracketed v6 literal.
IP="$(curl -4 -fsS --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
echo "main-host.sh done. Log into Coolify at http://${IP}:8000 to finish setup and add your apps."
