#!/usr/bin/env bash
# Wire an Uptime Kuma push URL into a host's backup.env, so backup.sh reports success.
# Usage (run from your machine):  set-backup-heartbeat.sh <ssh-target> <push-url>
# e.g.  set-backup-heartbeat.sh root@169.58.77.127 http://169.58.85.228:3001/api/push/AbC123
set -euo pipefail

TARGET="${1:-}"; URL="${2:-}"
if [[ -z "$TARGET" || -z "$URL" ]]; then
  echo "Usage: set-backup-heartbeat.sh <ssh-target> <push-url>" >&2
  exit 1
fi
KEY="${SSH_KEY:-$HOME/Desktop/vps-ssh-keys/bachir_vps_key}"

ssh -i "$KEY" -o BatchMode=yes "$TARGET" "URL='$URL' bash -s" << 'EOS'
set -euo pipefail
F=/etc/vps-infra/backup.env
touch "$F"
# Replace the line if present, append if not - keeps the file idempotent.
if grep -qE '^UPTIME_KUMA_PUSH_URL=' "$F"; then
  sed -i -E "s|^UPTIME_KUMA_PUSH_URL=.*|UPTIME_KUMA_PUSH_URL=\"${URL}\"|" "$F"
else
  echo "UPTIME_KUMA_PUSH_URL=\"${URL}\"" >> "$F"
fi
chmod 600 "$F"
echo "  $(hostname): heartbeat set"
# Prove it end to end rather than waiting until 3am to find out.
if curl -fsS --max-time 15 "${URL}?status=up&msg=wired-up" >/dev/null 2>&1; then
  echo "  $(hostname): test ping accepted"
else
  echo "  $(hostname): !! test ping FAILED - check the URL and that :3001 is reachable" >&2
fi
EOS
