#!/usr/bin/env bash
# Coolify install for the main app host.
set -euo pipefail
if [[ -d /data/coolify ]]; then
  echo "Coolify already appears installed at /data/coolify, skipping installer."
else
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi
echo "main-host.sh done. Log into Coolify at https://$(curl -s ifconfig.me):8000 to finish setup and add your apps."
