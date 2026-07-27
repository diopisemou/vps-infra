#!/usr/bin/env bash
# Installs restic + a systemd timer that runs backup.sh on a configurable schedule.
# Usage: run on the target server after common.sh, with r2.env already placed at
# /etc/vps-infra/r2.env (copy from backup/r2.env.example and fill in).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v restic >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y restic
fi

mkdir -p /etc/vps-infra
cp "$SCRIPT_DIR/backup.sh" /opt/vps-infra/backup.sh 2>/dev/null || \
  install -m 0755 "$SCRIPT_DIR/backup.sh" /opt/vps-infra/backup.sh

if [[ ! -f /etc/vps-infra/backup.env ]]; then
  cat > /etc/vps-infra/backup.env << 'EOF'
# systemd OnCalendar syntax. Examples:
#   daily at 3am:      *-*-* 03:00:00
#   every 6 hours:      00/6:00:00
#   weekly Sunday 2am:  Sun *-*-* 02:00:00
BACKUP_SCHEDULE="*-*-* 03:00:00"
EOF
  echo "Wrote default /etc/vps-infra/backup.env (daily 03:00). Edit BACKUP_SCHEDULE to change it."
fi

if [[ ! -f /etc/vps-infra/r2.env ]]; then
  echo "!! /etc/vps-infra/r2.env not found. Copy backup/r2.env.example there and fill in R2 credentials"
  echo "   before the timer's first run, or backups will fail silently until you do."
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
EOF

cat > /etc/systemd/system/restic-backup.timer << EOF
[Unit]
Description=Run restic-backup.service on a schedule

[Timer]
OnCalendar=${BACKUP_SCHEDULE}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now restic-backup.timer

echo "restic-setup.sh done. Schedule: ${BACKUP_SCHEDULE}"
echo "Trigger a backup right now with:  systemctl start restic-backup.service"
echo "Check status with:                systemctl list-timers restic-backup.timer"
