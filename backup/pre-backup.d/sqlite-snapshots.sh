#!/usr/bin/env bash
# pre-backup hook (installed to /etc/vps-infra/pre-backup.d/ on every host; backup.sh passes the stage dir).
#
# A live SQLite database in WAL mode is several files changing together (db, -wal, -shm); the volume tar
# copies them at different instants, and a restore of that copy can come back corrupt or missing the most
# recent writes. `sqlite3 .backup` uses SQLite's own online-backup API, which is safe while the owning
# process keeps writing (normal file locking — the volume is one filesystem). The Bidew hub's task queue,
# approvals and memory, Uptime Kuma, n8n and friends all live in SQLite files like this.
#
# Output: $STAGE/dumps/sqlite/<volume>/<path-in-volume>  (restore = copy the file back, delete any -wal/-shm)
set -uo pipefail
STAGE="${1:?stage dir}"
IMG=vps-infra-sqlite:1
OUT="$STAGE/dumps/sqlite"
mkdir -p "$OUT"
docker image inspect "$IMG" >/dev/null 2>&1 || \
  printf 'FROM alpine:3.20\nRUN apk add --no-cache sqlite\n' | docker build -q -t "$IMG" - >/dev/null || { echo "  ! cannot build $IMG"; exit 1; }

n=0
for vol in $(docker volume ls -q); do
  docker run --rm -v "${vol}:/v" -v "$OUT:/out" "$IMG" sh -c '
    find /v -type f \( -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db" \) -size +0 2>/dev/null | while read -r f; do
      head -c 15 "$f" 2>/dev/null | grep -q "SQLite format 3" || continue
      rel="${f#/v/}"; dst="/out/'"$vol"'/$rel"; mkdir -p "$(dirname "$dst")"
      if sqlite3 "$f" ".timeout 15000" ".backup \"$dst\"" && [ "$(sqlite3 "$dst" "PRAGMA quick_check;")" = ok ]; then
        echo "   + '"$vol"'/$rel"
      else
        echo "  ! '"$vol"'/$rel: online backup failed or did not verify"; rm -f "$dst"
      fi
    done'
  n=$((n+1))
done
echo "   scanned $n volume(s)"
