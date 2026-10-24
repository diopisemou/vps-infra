#!/usr/bin/env bash
# Switch every machine to a NEW R2 API key (after creating it in the Cloudflare dashboard), then prove each
# backup repository opens with it. Run it yourself in a terminal: it asks for the new key with hidden input,
# so the values never touch a command line, an environment dump or a chat.
#
# Order: (1) dashboard -> R2 -> Manage API tokens -> create "vps-infra-backups" token, Object Read & Write,
# scoped to bucket vps-infra-backups; (2) run this; (3) delete the OLD token in the dashboard;
# (4) python3 -I dr/escrow.py, then --show-kit and save the kit.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
dr_ready || exit 1
SERVERS=("${DR_HOSTS[@]:1}")
die() { echo "!! $*" >&2; exit 1; }

read -r -s -p "New R2 Access Key ID: " NEW_ID; echo
read -r -s -p "New R2 Secret Access Key: " NEW_SECRET; echo
[[ "$NEW_ID" =~ ^[0-9a-f]{32}$ ]] || die "an R2 Access Key ID is 32 hex characters"
[[ "$NEW_SECRET" =~ ^[0-9a-f]{64}$ ]] || die "an R2 Secret Access Key is 64 hex characters"
printf '%s\n%s\n' "$NEW_ID" "$NEW_SECRET" > "$DR_TMP/newkey"; chmod 600 "$DR_TMP/newkey"

echo "-- 1. the new key opens every repository (before anything is switched) --"
(umask 077; printf "[r2]\naws_access_key_id = %s\naws_secret_access_key = %s\n" "$NEW_ID" "$NEW_SECRET" > "$DR_TMP/aws-new")
for h in "${DR_HOSTS[@]}"; do
  dr_repo "$h"
  AWS_SHARED_CREDENTIALS_FILE="$DR_TMP/aws-new" restic cat config >/dev/null 2>&1 || die "$h: the NEW key cannot open its repository (wrong key, or not scoped to the bucket). Nothing was changed."
done
echo "   all ${#DR_HOSTS[@]} repositories open with the new key"

echo "-- 2. switch every server's r2.env --"
for h in "${SERVERS[@]}"; do
  ssh -o BatchMode=yes "$h" 'set -e; f=/etc/vps-infra/r2.env; { read -r id; read -r sec; }
    { while IFS= read -r l || [ -n "$l" ]; do case "$l" in
        R2_ACCESS_KEY_ID=*) printf "R2_ACCESS_KEY_ID=%s%s%s\n" "'"'"'" "$id" "'"'"'";;
        R2_SECRET_ACCESS_KEY=*) printf "R2_SECRET_ACCESS_KEY=%s%s%s\n" "'"'"'" "$sec" "'"'"'";;
        *) printf "%s\n" "$l";; esac; done < "$f"; } > "$f.rotating"
    chmod 600 "$f.rotating"; mv "$f.rotating" "$f"
    set -a; . "$f"; set +a
    export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${HOSTNAME_TAG:-$(hostname)}"
    export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" RESTIC_PASSWORD
    restic cat config >/dev/null' < "$DR_TMP/newkey" || die "$h: switch or verification failed — fix that host before deleting the old token"
  echo "   $h: switched and verified"
done

echo "-- 3. switch this Mac's kit file --"
( umask 077
  { while IFS= read -r l || [[ -n "$l" ]]; do case "$l" in
      R2_ACCESS_KEY_ID=*) printf "R2_ACCESS_KEY_ID='%s'\n" "$NEW_ID" ;;
      R2_SECRET_ACCESS_KEY=*) printf "R2_SECRET_ACCESS_KEY='%s'\n" "$NEW_SECRET" ;;
      *) printf '%s\n' "$l" ;; esac; done < "$DR_CREDS"; } > "$DR_CREDS.rotating" ) || die "could not write the kit"
chmod 600 "$DR_CREDS.rotating"; mv "$DR_CREDS.rotating" "$DR_CREDS"
rm -f "$DR_TMP/aws"   # lib.sh cached the old key there
for h in "${DR_HOSTS[@]}"; do dr_repo "$h"; restic cat config >/dev/null 2>&1 || die "$h: the Mac kit does not open it after the switch"; done
echo "   ~/.config/bidew/backup.env switched; all repositories open"

echo "-- 4. stale copies --"
for h in "${SERVERS[@]}"; do
  ssh -o BatchMode=yes "$h" 'rm -f /etc/vps-infra/r2.env.orig /etc/vps-infra/r2.env.bak-rotate' && echo "   $h: removed stale r2.env.orig (it held the old key)"
done
unset NEW_ID NEW_SECRET

echo
echo "DONE. Now: (3) delete the OLD R2 token in the Cloudflare dashboard,"
echo "then (4) python3 -I ~/Developer/vps-infra/dr/escrow.py && python3 -I ~/Developer/vps-infra/dr/escrow.py --show-kit"
