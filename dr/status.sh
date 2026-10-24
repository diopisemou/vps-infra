#!/usr/bin/env bash
# When was every machine last backed up — read from R2 itself, not from the machines (a dead or
# unpaid server cannot report on its own backups). Exit 1 if any host is older than MAX_AGE_H.
#
#   dr/status.sh            all hosts
#   dr/status.sh spare-01   one host
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
dr_ready || exit 1
MAX_AGE_H="${MAX_AGE_H:-36}"
hosts=("$@"); (( ${#hosts[@]} )) || hosts=("${DR_HOSTS[@]}")
stale=0; now=$(date -u +%s)
printf "%-15s %-21s %-7s %s\n" HOST "LATEST SNAPSHOT" "AGE" "TAGS"
for h in "${hosts[@]}"; do
  line=$(dr_latest "$h") || line=""
  if [[ -z "$line" ]]; then printf "%-15s %-21s %-7s %s\n" "$h" "NONE" "-" "!! no snapshot (or repo unreadable)"; stale=1; continue; fi
  t="${line%% *}"; tags="${line#* }"
  age_h=$(( (now - $(date -ju -f %Y-%m-%dT%H:%M:%SZ "$t" +%s)) / 3600 ))
  flag=""; (( age_h > MAX_AGE_H )) && { flag="  !! STALE"; stale=1; }
  printf "%-15s %-21s %-7s %s%s\n" "$h" "$t" "${age_h}h" "$tags" "$flag"
done
exit $stale
