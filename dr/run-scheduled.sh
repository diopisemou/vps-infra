#!/usr/bin/env bash
# launchd entry point for the DR jobs: runs one, logs it, and raises a macOS notification on failure —
# the alert that still works when every server (and the Uptime Kuma on one of them) is gone.
#
#   run-scheduled.sh backup | status | drill
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.local/bidew/logs"; mkdir -p "$LOG_DIR"
job="${1:?backup|status|drill}"
log="$LOG_DIR/dr-$job.log"
case "$job" in
  backup) cmd=("$HERE/mac-backup.sh") ;;
  status)
    # Hosts paused on purpose (dr/hibernate.sh writes them) are not "stale" — they are asleep.
    hosts=(); paused="$HOME/.local/bidew/dr-paused"
    . "$HERE/lib.sh"
    for h in "${DR_HOSTS[@]}"; do grep -qx "$h" "$paused" 2>/dev/null || hosts+=("$h"); done
    cmd=("$HERE/status.sh" "${hosts[@]}") ;;
  drill)  cmd=("$HERE/drill.sh") ;;
  *) echo "unknown job $job" >&2; exit 64 ;;
esac
{ echo "=== $(date '+%F %T') $job ==="; "${cmd[@]}"; } >> "$log" 2>&1
rc=$?
echo "=== exit $rc ===" >> "$log"
if (( rc != 0 )); then
  msg=$(tail -n 25 "$log" | grep -E '!!|FAIL|STALE|NONE' | tail -2 | tr '\n' ' ' | tr -d '"\\' | cut -c1-180)
  /usr/bin/osascript -e "display notification \"${msg:-see $log}\" with title \"Bidew backups: $job FAILED\" sound name \"Basso\"" 2>/dev/null
fi
exit $rc
