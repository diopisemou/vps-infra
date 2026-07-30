#!/usr/bin/env bash
# Installs restic + a systemd timer that runs backup.sh on a configurable schedule.
# Usage: run on the target server after common.sh, with r2.env already placed at
# /etc/vps-infra/r2.env (copy from backup/r2.env.example and fill in).
set -euo pipefail

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/diopisemou/vps-infra/main}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if ! command -v restic >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y restic
fi

mkdir -p /etc/vps-infra /opt/vps-infra

# $BASH_SOURCE is meaningless when this script is piped from curl, so fall back to
# fetching backup.sh from the repo rather than silently ending up without it.
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/backup.sh" ]]; then
  install -m 0755 "$SCRIPT_DIR/backup.sh" /opt/vps-infra/backup.sh
else
  curl -fsSL "$REPO_RAW_BASE/backup/backup.sh" -o /opt/vps-infra/backup.sh
  chmod 0755 /opt/vps-infra/backup.sh
fi

if [[ ! -f /etc/vps-infra/backup.env ]]; then
  cat > /etc/vps-infra/backup.env << 'EOF'
# systemd OnCalendar syntax. Examples:
#   daily at 3am:      *-*-* 03:00:00
#   every 6 hours:      00/6:00:00
#   weekly Sunday 2am:  Sun *-*-* 02:00:00
BACKUP_SCHEDULE="*-*-* 03:00:00"

# Optional. If set, backup.sh pings this URL after a successful run so a missed
# backup shows up as a DOWN monitor instead of failing silently. Create it in
# Uptime Kuma as a "Push" monitor and paste its push URL here.
UPTIME_KUMA_PUSH_URL=""
EOF
  echo "Wrote default /etc/vps-infra/backup.env (daily 03:00). Edit BACKUP_SCHEDULE to change it."
fi

# --- credentials -------------------------------------------------------------
# These are the R2 keys and the restic passphrase. Anything that can read this
# file can read and delete every backup, so it must not be world-readable.
if [[ -f /etc/vps-infra/r2.env ]]; then
  chown root:root /etc/vps-infra/r2.env
  chmod 600 /etc/vps-infra/r2.env
  missing=()
  for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY RESTIC_PASSWORD; do
    val="$(grep -E "^${v}=" /etc/vps-infra/r2.env | head -1 | cut -d= -f2- || true)"
    case "$val" in
      ""|your-*|choose-a-strong*) missing+=("$v") ;;
    esac
  done
  if (( ${#missing[@]} )); then
    echo "!! /etc/vps-infra/r2.env is missing real values for: ${missing[*]}" >&2
    echo "!! Fill them in, then re-run. Not enabling the timer against a broken config." >&2
    exit 1
  fi
  echo "   r2.env present and complete (mode 600)"
else
  echo "!! /etc/vps-infra/r2.env not found. Copy backup/r2.env.example there and fill it in." >&2
  echo "!! Refusing to enable a timer that would fail every night. Aborting." >&2
  exit 1
fi

source /etc/vps-infra/backup.env

cat > /etc/systemd/system/restic-backup.service << 'EOF'
[Unit]
Description=Restic backup to Cloudflare R2
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/vps-infra/backup.sh
# Backups are IO-heavy and must never starve the apps sharing this box.
Nice=10
IOSchedulingClass=idle
EOF

cat > /etc/systemd/system/restic-backup.timer << EOF
[Unit]
Description=Run restic-backup.service on a schedule

[Timer]
OnCalendar=${BACKUP_SCHEDULE}
# Every host would otherwise hit R2 at exactly the same second.
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now restic-backup.timer

echo "restic-setup.sh done. Schedule: ${BACKUP_SCHEDULE} (+ up to 30min jitter)"
echo "Trigger a backup right now with:  systemctl start restic-backup.service"
echo "Check status with:                systemctl list-timers restic-backup.timer"
