#!/usr/bin/env bash
# Replace the restic passphrase of EVERY backup repository (all hosts share one), safely:
#
#   1. generate a long random passphrase (never printed, never on a command line)
#   2. ADD it as a second key to every repository, and prove each one opens with it
#   3. switch /etc/vps-infra/r2.env on every server and ~/.config/bidew/backup.env here; prove each opens
#   4. only then REMOVE the old key(s) from every repository
#
# Any failure before step 4 aborts with the old passphrase still valid everywhere (nothing is lost — a
# repository with an extra key is fine). Afterwards: re-run dr/escrow.py and save the new kit (--show-kit).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
dr_ready || exit 1
SERVERS=("${DR_HOSTS[@]:1}")
die() { echo "!! $*" >&2; echo "!! ABORTED — the old passphrase is still valid everywhere." >&2; exit 1; }

echo "-- 0. nothing may be backing up right now --"
pgrep -f mac-backup.sh >/dev/null && die "a Mac backup is running"
for h in "${SERVERS[@]}"; do
  st=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" 'systemctl is-active restic-backup.service' 2>/dev/null)
  [[ "$st" == activating || "$st" == active ]] && die "$h is mid-backup"
  ssh -o BatchMode=yes "$h" 'test -r /etc/vps-infra/r2.env' || die "$h: cannot read /etc/vps-infra/r2.env"
done

NEW="$DR_TMP/newpass"
(umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 > "$NEW")
[[ $(wc -c < "$NEW" | tr -d ' ') == 48 ]] || die "could not generate a passphrase"

echo "-- 1. add the new key to every repository --"
for h in "${DR_HOSTS[@]}"; do
  dr_repo "$h"
  restic key list --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; [print(k["id"]) for k in json.load(sys.stdin)]' > "$DR_TMP/old-$h" \
    || die "$h: cannot list keys with the current passphrase"
  [[ -s "$DR_TMP/old-$h" ]] || die "$h: no existing keys found"
  restic key add --new-password-file "$NEW" >/dev/null 2>&1 || die "$h: key add failed"
  ( unset RESTIC_PASSWORD_COMMAND; RESTIC_PASSWORD_FILE="$NEW" restic cat config >/dev/null 2>&1 ) || die "$h: new key does not open the repository"
  echo "   $h: new key added and verified ($(wc -l < "$DR_TMP/old-$h" | tr -d ' ') old key(s) to retire)"
done

echo "-- 2. switch every server's r2.env --"
for h in "${SERVERS[@]}"; do
  # The passphrase travels on stdin and is written with shell builtins only — never in any argv.
  ssh -o BatchMode=yes "$h" 'set -e; f=/etc/vps-infra/r2.env; new=$(cat); [ ${#new} -eq 48 ]
    { while IFS= read -r l || [ -n "$l" ]; do case "$l" in RESTIC_PASSWORD=*) printf "RESTIC_PASSWORD=%s%s%s\n" "'"'"'" "$new" "'"'"'";; *) printf "%s\n" "$l";; esac; done < "$f"; } > "$f.rotating"
    chmod 600 "$f.rotating"; mv "$f.rotating" "$f"
    set -a; . "$f"; set +a
    export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${HOSTNAME_TAG:-$(hostname)}"
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" RESTIC_PASSWORD
    restic cat config >/dev/null' < "$NEW" || die "$h: r2.env switch or its verification failed (that host may now hold the new passphrase — still valid)"
  echo "   $h: r2.env switched, opens its repository with the new passphrase"
done

echo "-- 3. switch this Mac's kit file --"
( umask 077; new=$(cat "$NEW")
  { while IFS= read -r l || [[ -n "$l" ]]; do
      case "$l" in RESTIC_PASSWORD=*) printf "RESTIC_PASSWORD='%s'\n" "$new" ;; *) printf '%s\n' "$l" ;; esac
    done < "$DR_CREDS"; } > "$DR_CREDS.rotating" ) || die "could not write $DR_CREDS.rotating"
chmod 600 "$DR_CREDS.rotating"; mv "$DR_CREDS.rotating" "$DR_CREDS"
for h in "${DR_HOSTS[@]}"; do dr_repo "$h"; restic cat config >/dev/null 2>&1 || die "$h: the Mac's kit does not open it after the switch"; done
echo "   ~/.config/bidew/backup.env switched; all ${#DR_HOSTS[@]} repositories open with it"

echo "-- 4. retire the old key(s) --"
for h in "${DR_HOSTS[@]}"; do
  dr_repo "$h"
  while IFS= read -r id; do restic key remove "$id" >/dev/null 2>&1 || echo "   ! $h: could not remove old key $id"; done < "$DR_TMP/old-$h"
  n=$(restic key list --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  echo "   $h: $n key(s) remain"
done

echo
echo "DONE. The old passphrase opens nothing now. Next, by you:"
echo "  python3 -I ~/Developer/vps-infra/dr/escrow.py            # update Infisical bidew-dr"
echo "  python3 -I ~/Developer/vps-infra/dr/escrow.py --show-kit # replace the kit in your password manager"
