#!/usr/bin/env bash
# Prove a backup can actually be restored. Run ON a host that has /etc/vps-infra/r2.env.
#
#   restore-drill.sh <source-hostname> [target-dir]
#   e.g.  restore-drill.sh main-host
#
# Restores another host's latest snapshot into a scratch directory and checks the
# contents are real and usable. Touches nothing live - safe to run on a spare box.
#
# Why this exists: "the timer is enabled" and "the data comes back" are different
# claims. Only this one matters, and it is the one nobody checks until it is too
# late to matter.
set -uo pipefail

SRC_HOST="${1:-}"
TARGET="${2:-/var/tmp/restore-drill}"
if [[ -z "$SRC_HOST" ]]; then
  echo "Usage: restore-drill.sh <source-hostname> [target-dir]" >&2
  exit 1
fi

pass=0; fail=0
ok(){   echo "  PASS  $*"; pass=$((pass+1)); }
bad(){  echo "  FAIL  $*"; fail=$((fail+1)); }
info(){ echo "  ..    $*"; }

set -a; . /etc/vps-infra/r2.env; set +a
export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${SRC_HOST}"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

echo "=== restore drill: $SRC_HOST -> $TARGET (on $(hostname)) ==="

echo "-- 1. repository reachable --"
if restic snapshots >/dev/null 2>&1; then
  ok "opened repo for '$SRC_HOST' with this host's credentials"
else
  bad "cannot open repo - wrong passphrase or credentials"; exit 1
fi

echo "-- 2. integrity (structure + 5% of pack data actually re-read) --"
if restic check --read-data-subset=5% 2>&1 | tail -3 | grep -qi 'no errors were found'; then
  ok "restic check reported no errors"
else
  bad "restic check reported problems"
fi

echo "-- 3. restore latest snapshot --"
rm -rf "$TARGET"; mkdir -p "$TARGET"
if restic restore latest --target "$TARGET" >/dev/null 2>&1; then
  ok "restored to $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
else
  bad "restore failed"; exit 1
fi

echo "-- 4. database dumps --"
shopt -s nullglob
dumps=("$TARGET"/var/backups/vps-infra-stage/dumps/*.sql)
if (( ${#dumps[@]} == 0 )); then
  info "no SQL dumps in this snapshot (host may run no databases)"
else
  for d in "${dumps[@]}"; do
    n=$(basename "$d")
    # pg_dumpall writes "PostgreSQL database CLUSTER dump" - matching only on
    # "database dump" misses it and reports a perfectly good backup as invalid.
    if head -5 "$d" | grep -qiE 'PostgreSQL database (cluster )?dump|MySQL dump'; then
      tables=$(grep -c '^CREATE TABLE' "$d" 2>/dev/null || echo 0)
      roles=$(grep -c '^CREATE ROLE' "$d" 2>/dev/null || echo 0)
      copies=$(grep -c '^COPY ' "$d" 2>/dev/null || echo 0)
      if grep -qiE 'PostgreSQL database (cluster )?dump complete|Dump completed' "$d"; then
        ok "$n: valid, complete ($tables tables, $roles roles, $copies COPY blocks, $(du -h "$d"|cut -f1))"
      else
        bad "$n: header present but TRUNCATED - no completion marker"
      fi
    else
      bad "$n: does not look like a database dump"
    fi
  done
fi

echo "-- 5. docker volume archives --"
vols=("$TARGET"/var/backups/vps-infra-stage/volumes/*.tar.gz)
if (( ${#vols[@]} == 0 )); then
  info "no volume archives in this snapshot"
else
  for v in "${vols[@]}"; do
    n=$(basename "$v")
    if gzip -t "$v" 2>/dev/null; then
      c=$(tar tzf "$v" 2>/dev/null | wc -l | tr -d ' ')
      (( c > 0 )) && ok "$n: gzip valid, $c entries" || bad "$n: gzip valid but EMPTY"
    else
      bad "$n: corrupt gzip"
    fi
  done
fi
shopt -u nullglob

echo "-- 6. PaaS control plane --"
CO="$TARGET/data/coolify"
if [[ -d "$CO" ]]; then
  if [[ -f "$CO/source/.env" ]]; then
    if grep -qE '^APP_KEY=.+' "$CO/source/.env"; then
      h=$(grep -E '^APP_KEY=' "$CO/source/.env" | head -1 | cut -d= -f2- | tr -d '"' | sha256sum | cut -c1-12)
      ok "coolify source/.env restored, APP_KEY present (sha $h)"
      echo "        ^ compare with live: grep '^APP_KEY=' /data/coolify/source/.env | cut -d= -f2- | tr -d '\"' | sha256sum | cut -c1-12"
    else
      bad "coolify source/.env restored but has NO APP_KEY - db secrets would be undecryptable"
    fi
  else
    bad "coolify present but source/.env MISSING - db secrets would be undecryptable"
  fi
  [[ -d "$CO/ssh" ]] && ok "coolify ssh keys restored" || bad "coolify ssh keys missing"
  [[ -d "$CO/applications" ]] && ok "coolify application definitions restored" || info "no application definitions yet"
fi
DK="$TARGET/etc/dokploy"
if [[ -d "$DK" ]]; then
  ok "dokploy control plane restored ($(du -sh "$DK"|cut -f1))"
  [[ -d "$DK/ssh" ]] && ok "dokploy ssh keys restored" || info "no dokploy ssh dir"
fi
[[ -d "$CO" || -d "$DK" ]] || info "no PaaS control plane on this host"

echo "-- 7. vps-infra config --"
[[ -f "$TARGET/etc/vps-infra/r2.env" ]] \
  && ok "r2.env restored (note: encrypted WITH the passphrase you'd need to read it)" \
  || bad "r2.env not in snapshot"

echo
echo "=== $pass passed, $fail failed ==="
echo "Scratch data left at $TARGET - remove it when done:  rm -rf $TARGET"
exit $(( fail > 0 ))
