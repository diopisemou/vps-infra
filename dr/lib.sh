# Sourced by every dr/ script. Opens the restic repository of one host in the shared R2 bucket using
# ~/.config/bidew/backup.env (the same five values as /etc/vps-infra/r2.env on every server).
# Secrets never enter an environment variable or a command line: the passphrase comes from
# RESTIC_PASSWORD_COMMAND and the R2 keys from a 0600 credentials file in a private temp dir.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
DR_CREDS="${BIDEW_BACKUP_CREDS:-$HOME/.config/bidew/backup.env}"
DR_HOSTS=(mac-main spare-01 main-host monitoring neobank meet-sso-misc xaalis-prod)
DR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bidew-dr.XXXXXX")"; chmod 700 "$DR_TMP"
trap 'rm -rf "$DR_TMP"' EXIT

dr_ready() {
  [[ -r "$DR_CREDS" ]] || { echo "!! $DR_CREDS missing — see dr/DISASTER-RECOVERY.md, 'Recovery kit'" >&2; return 1; }
  command -v restic >/dev/null || { echo "!! restic not installed (brew install restic)" >&2; return 1; }
}
_dr_get() { bash -c 'set -a; . "$1"; printf %s "${!2}"' _ "$DR_CREDS" "$1"; }

# dr_repo <host>: point restic at that host's repository.
dr_repo() {
  dr_ready || return 1
  export RESTIC_REPOSITORY="s3:https://$(_dr_get R2_ACCOUNT_ID).r2.cloudflarestorage.com/$(_dr_get R2_BUCKET)/$1"
  export RESTIC_PASSWORD_COMMAND="bash -c 'set -a; . \"$DR_CREDS\"; printf %s \"\$RESTIC_PASSWORD\"'"
  export RESTIC_CACHE_DIR="$HOME/Library/Caches/restic"
  if [[ ! -s "$DR_TMP/aws" ]]; then
    (umask 077; bash -c 'set -a; . "$1"; printf "[r2]\naws_access_key_id = %s\naws_secret_access_key = %s\n" "$R2_ACCESS_KEY_ID" "$R2_SECRET_ACCESS_KEY"' _ "$DR_CREDS" > "$DR_TMP/aws")
  fi
  export AWS_SHARED_CREDENTIALS_FILE="$DR_TMP/aws" AWS_PROFILE=r2
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
}

# dr_latest <host> -> "ISO-time TAGS" of the newest snapshot, or nothing.
dr_latest() {
  dr_repo "$1" || return 1
  restic snapshots --host "$1" --latest 1 --json 2>/dev/null \
    | /usr/bin/python3 -c '
import json, re, sys, datetime as d
s = json.load(sys.stdin) or []
if s:
    t = re.sub(r"(\.\d+)", "", s[-1]["time"]).replace("Z", "+00:00")   # restic writes the HOST local zone, ns precision
    utc = d.datetime.fromisoformat(t).astimezone(d.timezone.utc)
    print(utc.strftime("%Y-%m-%dT%H:%M:%SZ"), ",".join(s[-1].get("tags") or []))'
}
