#!/usr/bin/env bash
# At-a-glance health of every host in inventory.yml. Read-only, safe to run anytime.
# Usage: scripts/fleet-status.sh
set -uo pipefail

KEY="${SSH_KEY:-$HOME/Desktop/vps-ssh-keys/bachir_vps_key}"

HOSTS=(
  "main-host     169.58.77.127"
  "neobank       169.58.79.167"
  "meet-sso-misc 2.28.13.102"
  "monitoring    169.58.85.228"
  "spare-01      169.58.97.123"
)

printf "%-14s %-6s %-16s %-6s %-5s %-22s %s\n" \
       HOST LOAD DISK MEM CTRS "LAST BACKUP" BACKUP-STATE
printf '%.0s-' {1..104}; echo

for entry in "${HOSTS[@]}"; do
  name="${entry%% *}"; ip="${entry##* }"
  out=$(ssh -i "$KEY" -o ConnectTimeout=10 -o BatchMode=yes "root@$ip" bash -s 2>/dev/null << 'EOS'
load=$(awk '{printf "%.2f", $1}' /proc/loadavg)
disk=$(df -h / | awk 'NR==2{print $3"/"$2" "$5}')
mem=$(free -m | awk '/Mem:/{printf "%d%%", $3*100/$2}')
ctrs=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
unhealthy=$(docker ps --filter health=unhealthy -q 2>/dev/null | wc -l | tr -d ' ')
[[ "$unhealthy" != "0" ]] && ctrs="$ctrs(!$unhealthy)"
state=$(systemctl show restic-backup.service -p Result --value 2>/dev/null)
last=$(systemctl show restic-backup.service -p ExecMainExitTimestamp --value 2>/dev/null | cut -d' ' -f2-3)
[[ -z "$last" ]] && last="never"
echo "$load|$disk|$mem|$ctrs|$last|${state:-unknown}"
EOS
)
  if [[ -z "$out" ]]; then
    printf "%-14s %s\n" "$name" "UNREACHABLE"
    continue
  fi
  IFS='|' read -r load disk mem ctrs last state <<< "$out"
  printf "%-14s %-6s %-16s %-6s %-5s %-22s %s\n" "$name" "$load" "$disk" "$mem" "$ctrs" "$last" "$state"
done
