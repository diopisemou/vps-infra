#!/usr/bin/env bash
# Monthly restore drill, run FROM THE MAC: prove the backups in R2 open and restore into something usable,
# using nothing but the recovery-kit credentials — exactly the position after every server is gone.
# Touches nothing live; restores into a temp dir and deletes it.
#
#   dr/drill.sh            every host
#   dr/drill.sh spare-01   one host
#
# Per server: open the repo, re-read 3% of its data, restore the database dumps, and check each one
# (pg_dumpall completion marker, SQLite PRAGMA integrity_check). For mac-main: restore two repos' .git and
# run `git fsck`, and check the Paperclip dump is a complete gzip.
set -o pipefail   # no -u: macOS bash 3.2 treats an empty "${arr[@]}" as unbound
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
dr_ready || exit 1
hosts=("$@"); (( ${#hosts[@]} )) || hosts=("${DR_HOSTS[@]}")
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }

for h in "${hosts[@]}"; do
  echo "=== $h ==="
  dr_repo "$h"
  if ! restic cat config >/dev/null 2>&1; then bad "$h: repository does not open with the recovery-kit credentials"; continue; fi
  if restic check --read-data-subset=3% >/dev/null 2>&1; then ok "$h: integrity (3% of data re-read)"; else bad "$h: restic check reported errors"; fi
  T="$DR_TMP/restore-$h"; mkdir -p "$T"
  if [[ "$h" == mac-main ]]; then
    for r in bidew-ltd/bidew-ai alminhaaj; do
      inc="$HOME/Developer/$r/.git"
      if restic restore latest --host "$h" --target "$T" --include "$inc" >/dev/null 2>&1 && \
         git --git-dir "$T$inc" fsck --no-dangling --no-progress >/dev/null 2>&1; then
        ok "$h: $r — .git restored, git fsck clean ($(git --git-dir "$T$inc" for-each-ref | wc -l | tr -d ' ') refs)"
      else bad "$h: $r — .git did not restore or fsck failed"; fi
    done
    pc=$(restic ls latest --host "$h" 2>/dev/null | grep -E '/data/backups/paperclip-.*\.sql\.gz$' | tail -1)
    if [[ -n "$pc" ]] && restic restore latest --host "$h" --target "$T" --include "$pc" >/dev/null 2>&1 && gzip -t "$T$pc" 2>/dev/null; then
      ok "$h: Paperclip dump $(basename "$pc") restored, gzip intact"
    else bad "$h: Paperclip dump missing or corrupt"; fi
  else
    if ! restic restore latest --host "$h" --target "$T" --include /var/backups/vps-infra-stage/dumps >/dev/null 2>&1; then
      bad "$h: could not restore database dumps"; rm -rf "$T"; continue
    fi
    shopt -s nullglob
    D="$T/var/backups/vps-infra-stage/dumps"
    sqls=("$D"/*.sql); lites=()
    while IFS= read -r f; do lites+=("$f"); done < <(find "$D/sqlite" -type f 2>/dev/null)
    if [[ -f "$D/MANIFEST" ]]; then
      found=$(grep -vc ' skipped$' "$D/MANIFEST"); failed=$(grep -c ' FAILED$' "$D/MANIFEST")
      (( failed )) && bad "$h: $failed of $found database dump(s) FAILED at backup time: $(grep ' FAILED$' "$D/MANIFEST" | cut -d' ' -f1 | tr '\n' ' ')"
      (( found && !failed )) && ok "$h: all $found database container(s) dumped at backup time"
      (( found )) || echo "  ..    $h: backup found no database containers"
    else
      echo "  ..    $h: snapshot predates the dump MANIFEST (2026-10-24) — cannot tell 'no databases' from 'dumps failed'"
    fi
    for f in "${sqls[@]}"; do
      if grep -qiE 'PostgreSQL database (cluster )?dump complete|Dump completed' "$f"; then ok "$h: $(basename "$f") complete ($(du -h "$f" | cut -f1))"
      else bad "$h: $(basename "$f") truncated or not a dump"; fi
    done
    for f in "${lites[@]}"; do
      if [[ "$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>&1)" == ok ]]; then ok "$h: sqlite ${f#$D/sqlite/} integrity ok"
      else bad "$h: sqlite ${f#$D/sqlite/} failed integrity_check"; fi
    done
    shopt -u nullglob
  fi
  rm -rf "$T"
done
echo; echo "drill: $pass passed, $fail failed"
(( fail == 0 ))
