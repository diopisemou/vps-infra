#!/usr/bin/env bash
# Install the Mac's DR jobs as LaunchAgents (idempotent; re-run after moving the repo).
#   io.bidew.dr-backup  nightly 02:30  -> dr/mac-backup.sh   (a missed run fires on wake)
#   io.bidew.dr-status  Mondays 09:15  -> dr/status.sh       (any server whose backups stopped)
#   io.bidew.dr-drill   1st of month 04:00 -> dr/drill.sh    (restore from R2 actually works)
# Failures raise a macOS notification (dr/run-scheduled.sh). Logs: ~/.local/bidew/logs/dr-*.log
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA" "$HOME/.local/bidew/logs"
[[ -r "$HOME/.config/bidew/backup.env" ]] || { echo "!! ~/.config/bidew/backup.env missing — see DISASTER-RECOVERY.md 'Recovery kit'" >&2; exit 1; }
command -v restic >/dev/null || brew install restic

plist() { # label job calendar-dict
  cat > "$LA/$1.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HERE/run-scheduled.sh</string><string>$2</string></array>
  <key>StartCalendarInterval</key>$3
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/.local/bidew/logs/dr-launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/.local/bidew/logs/dr-launchd.log</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LA/$1.plist"
  echo "installed $1"
}
plist io.bidew.dr-backup backup '<dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>30</integer></dict>'
plist io.bidew.dr-status status '<dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>15</integer></dict>'
plist io.bidew.dr-drill  drill  '<dict><key>Day</key><integer>1</integer><key>Hour</key><integer>4</integer><key>Minute</key><integer>0</integer></dict>'
