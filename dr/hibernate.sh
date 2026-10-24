#!/usr/bin/env bash
# Run this BEFORE stopping servers / pausing for months. Run it from the Mac.
#
# It takes a fresh backup of every server and of this Mac, tags each one `hibernate` (retention never prunes a
# hibernate snapshot — they outlive any pause), proves each one is readable from R2, and writes a dated
# hibernation record into the Second Brain saying exactly what was saved and how to wake everything up.
# Only after it prints ALL GREEN is it safe to cancel a server.
#
#   dr/hibernate.sh                 everything
#   dr/hibernate.sh spare-01 ...    only these servers (the Mac is always included)
#
# Background: April-July 2026 the servers went unpaid and were deleted with everything on them. This exists
# so that a pause costs nothing but the time to restore.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
dr_ready || exit 1
servers=("$@"); (( ${#servers[@]} )) || servers=("${DR_HOSTS[@]:1}")   # every host except mac-main
started=$(date -u +%s); stamp=$(date +%Y-%m-%d)
fail=0; report=()

say() { echo "$*"; report+=("$*"); }

say "## 1. Final backup of every server (tag: hibernate)"
for h in "${servers[@]}"; do
  echo "-- $h: backing up (this can take several minutes) --"
  if ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" 'HIBERNATE=1 /opt/vps-infra/backup.sh' > "$DR_TMP/$h.log" 2>&1; then
    say "- $h: backup finished"
  else
    say "- **$h: BACKUP FAILED** — last lines: $(tail -3 "$DR_TMP/$h.log" | tr '\n' ' ')"; fail=1
  fi
done

say ""; say "## 2. Final backup of mac-main (tag: hibernate)"
if HIBERNATE=1 "$HERE/mac-backup.sh" > "$DR_TMP/mac.log" 2>&1; then say "- mac-main: backup finished"
else say "- **mac-main: BACKUP FAILED** — $(tail -3 "$DR_TMP/mac.log" | tr '\n' ' ')"; fail=1; fi

say ""; say "## 3. Proof, read back from R2 (not from the machines)"
for h in mac-main "${servers[@]}"; do
  line=$(dr_latest "$h") || line=""
  t="${line%% *}"; tags="${line#* }"
  if [[ -z "$line" ]]; then say "- **$h: NO SNAPSHOT IN R2**"; fail=1; continue; fi
  snap_s=$(date -ju -f %Y-%m-%dT%H:%M:%SZ "$t" +%s)
  if [[ ",$tags," != *",hibernate,"* ]] || (( snap_s < started - 300 )); then
    say "- **$h: newest snapshot ($t, tags $tags) is NOT this hibernation's**"; fail=1; continue
  fi
  dr_repo "$h"
  if restic check --read-data-subset=2% > "$DR_TMP/check-$h" 2>&1; then
    say "- $h: snapshot $t verified (structure + 2% of data re-read)"
  else
    say "- **$h: restic check FAILED** — $(tail -2 "$DR_TMP/check-$h" | tr '\n' ' ')"; fail=1
  fi
done

VAULT="$HOME/Developer/Second Brain/30-projects"
note="$VAULT/Hibernation $stamp.md"
{
  echo "---"; echo "tags: [ops, disaster-recovery]"; echo "date: $stamp"; echo "---"; echo
  echo "# Hibernation $stamp"; echo
  if (( fail )); then echo "> [!danger] NOT safe to cancel servers — see the failures below."; else echo "> [!success] All green: every machine has a verified \`hibernate\` snapshot in R2. Safe to cancel servers."; fi
  echo; printf '%s\n' "${report[@]}"; echo
  echo "## Keep paying for / keep alive while paused"
  echo "- **Cloudflare** (R2 bucket \`vps-infra-backups\` = every backup, DNS for bidew.io). Free tier, but keep the account in good standing."
  echo "- **Domains**: auto-renew ON for bidew.io and every product domain — a lapsed domain loses email and every login tied to it."
  echo "- **GitHub** (code), **Infisical** (secrets + the bidew-dr recovery copy), **Google Workspace** if mail must keep working."
  echo "- The **recovery kit** in your password manager: without its 5 values the backups cannot be opened."
  echo; echo "## Waking up"; echo "Follow \`vps-infra/dr/DISASTER-RECOVERY.md\` → *Restore after a pause*."
} > "$DR_TMP/note.md"
if [[ -d "$VAULT" ]]; then cp "$DR_TMP/note.md" "$note"; echo; echo "Record written: $note"; else cat "$DR_TMP/note.md"; fi

echo
if (( fail )); then echo "!! NOT ALL GREEN — do not cancel anything yet."; exit 1; fi
echo "ALL GREEN — every machine has a verified hibernate snapshot in R2."
