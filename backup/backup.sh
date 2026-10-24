#!/usr/bin/env bash
# Runs on each server (via systemd timer). Dumps DBs + tars volumes, then restic push.
set -euo pipefail

ENV_FILE="/etc/vps-infra/backup.env"
R2_ENV_FILE="/etc/vps-infra/r2.env"
# NB: plain '[[ -f x ]] && source x' would abort the whole script under `set -e`
# when the file is absent, because the failed test becomes the list's exit status.
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
if [[ -f "$R2_ENV_FILE" ]]; then source "$R2_ENV_FILE"; fi

# Fail loudly and specifically rather than building a malformed repo URL.
missing=()
for v in R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY RESTIC_PASSWORD; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if (( ${#missing[@]} )); then
  echo "!! Missing required setting(s): ${missing[*]}" >&2
  echo "!! Fill them into $R2_ENV_FILE (template: backup/r2.env.example). Aborting." >&2
  exit 1
fi

HOSTNAME_TAG="${HOSTNAME_TAG:-$(hostname)}"
export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${HOSTNAME_TAG}"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RESTIC_PASSWORD

STAGE=/var/backups/vps-infra-stage
rm -rf "$STAGE" && mkdir -p "$STAGE/dumps" "$STAGE/volumes"

echo "-- dumping databases from running containers --"
# MANIFEST: one line per database container found and whether its dump worked. dr/drill.sh fails on any
# FAILED line, so "no dumps" can never again read as "this host runs no databases".
: > "$STAGE/dumps/MANIFEST"
for cid in $(docker ps --format '{{.ID}} {{.Image}}' | awk '{print $1}'); do
  image=$(docker inspect --format '{{.Config.Image}}' "$cid")
  name=$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')
  # Detect the ENGINE, not the image name: every image built on the official postgres/mysql/mariadb ones
  # sets PG_VERSION / MYSQL_VERSION / MARIADB_VERSION. Matching on the name alone skipped
  # pgvector/pgvector:* on spare-01 — the hub's Postgres and the content team's database were never
  # dumped, only tarred live (often unrestorable). Found by dr/drill.sh on 2026-10-24.
  envs=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid")
  engine="$image"
  if grep -q '^PG_VERSION=' <<<"$envs"; then engine=postgres
  elif grep -qE '^(MYSQL_VERSION|MYSQL_MAJOR|MARIADB_VERSION)=' <<<"$envs"; then engine=mysql; fi
  case "$engine" in
    postgres*|*postgres*)
      # A container built FROM postgres is not necessarily a server (Xaalis's backup sidecars only carry the
      # client tools). Only a running server has its socket — skip the rest instead of recording a failure.
      if ! docker exec "$cid" sh -c 'ls /var/run/postgresql/.s.PGSQL.* >/dev/null 2>&1'; then
        echo "   . $name: postgres client only, no server running (skipped)"; echo "$name postgres-client skipped" >> "$STAGE/dumps/MANIFEST"
        continue
      fi
      user=$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null || echo postgres)
      if docker exec "$cid" pg_dumpall -U "$user" > "$STAGE/dumps/${name}.sql" 2>/dev/null; then
        echo "$name postgres ok" >> "$STAGE/dumps/MANIFEST"
      else
        echo "  ! pg_dumpall failed for $name (skipping)"; echo "$name postgres FAILED" >> "$STAGE/dumps/MANIFEST"
      fi
      ;;
    mysql*|mariadb*)
      pass=$(docker exec "$cid" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
      docker exec "$cid" sh -c "\$(command -v mysqldump || command -v mariadb-dump) -uroot -p'$pass' --all-databases" > "$STAGE/dumps/${name}.sql" 2>/dev/null \
        && echo "$name mysql ok" >> "$STAGE/dumps/MANIFEST" \
        || { echo "  ! mysqldump failed for $name (skipping)"; echo "$name mysql FAILED" >> "$STAGE/dumps/MANIFEST"; }
      ;;
  esac
done

# Host-specific pre-backup hooks: consistent copies of things a file tar would catch mid-write (a live
# SQLite database in WAL mode, say). Each hook gets the stage dir as $1 and writes into "$1/dumps".
# A failing hook is reported, never fatal: the rest of the backup is still worth taking.
shopt -s nullglob
for hook in /etc/vps-infra/pre-backup.d/*.sh; do
  echo "-- pre-backup hook: $(basename "$hook") --"
  bash "$hook" "$STAGE" || echo "  ! hook $(basename "$hook") failed (continuing)"
done
shopt -u nullglob

echo "-- snapshotting named docker volumes --"
# UNCOMPRESSED tar on purpose: restic compresses and de-duplicates itself, but cannot see inside a gzip
# stream, so a nightly .tar.gz is a brand-new blob every night even when one byte changed. That is how
# vps-infra-backups reached the 10 GB R2 free tier by 2026-10-24.
# Volumes that are a CACHE of something re-downloadable (model weights, docker-in-docker image layers) are
# skipped — on spare-01 they were 8.2 of 8.4 GB. Default patterns below; a host can add its own, one shell
# glob per line, in /etc/vps-infra/backup-exclude-volumes.conf. Skipped volumes are listed in
# dumps/SKIPPED-VOLUMES so a restore knows to re-pull them rather than look for them.
EXCLUDE_VOLS=('*ollama*' '*runner_docker*' '*buildkit*')
if [[ -f /etc/vps-infra/backup-exclude-volumes.conf ]]; then
  while IFS= read -r line; do line="${line%%#*}"; line="$(echo "$line" | xargs || true)"; [[ -n "$line" ]] && EXCLUDE_VOLS+=("$line"); done \
    < /etc/vps-infra/backup-exclude-volumes.conf
fi
: > "$STAGE/dumps/SKIPPED-VOLUMES"
for vol in $(docker volume ls -q); do
  skip=0; for pat in "${EXCLUDE_VOLS[@]}"; do [[ "$vol" == $pat ]] && skip=1; done
  if (( skip )); then echo "   - $vol (re-downloadable cache, skipped)"; echo "$vol" >> "$STAGE/dumps/SKIPPED-VOLUMES"; continue; fi
  docker run --rm -v "${vol}:/from" -v "$STAGE/volumes:/to" alpine \
    sh -c "tar -C /from -cf /to/${vol}.tar . 2>/dev/null || true"
done

echo "-- init restic repo if needed --"
restic snapshots >/dev/null 2>&1 || restic init

# Clear locks left by a restic that died mid-run. Plain `unlock` only removes STALE
# locks (owner process gone, or older than 30 min) - never one a live run holds.
# Without this, one crashed run on monitoring (2026-08-15) blocked every
# `forget --prune` for seven weeks: snapshots kept landing, nothing was pruned, the
# unit failed nightly, and the heartbeat never pinged.
restic unlock >/dev/null 2>&1 || true

echo "-- assembling backup targets --"
# An unmatched /opt/*/docker-compose.yml glob would be passed through literally and
# make restic error out, failing the whole backup on a host that has no stacks yet.
TARGETS=("$STAGE/dumps" "$STAGE/volumes" /etc/vps-infra)

# PaaS control-plane state. This is NOT in any docker volume, and without it a
# restore is far less useful than it looks:
#   /data/coolify/source/.env holds Coolify's APP_KEY, which encrypts the secrets
#   stored in coolify-db - restore the dump without it and the credentials in it
#   cannot be decrypted. It also holds the deploy SSH keys and app definitions.
#   /etc/dokploy holds the equivalent for Dokploy.
for p in /data/coolify /etc/dokploy /opt/vps-infra; do
  [[ -d "$p" ]] && { TARGETS+=("$p"); echo "   + $p"; }
done

shopt -s nullglob
for f in /opt/*/docker-compose.yml; do TARGETS+=("$f"); echo "   + $f"; done
shopt -u nullglob

# Host-specific extras, one path per line (globs allowed, # for comments).
INCLUDE_FILE=/etc/vps-infra/backup-include.conf
if [[ -f "$INCLUDE_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs || true)"
    [[ -z "$line" ]] && continue
    shopt -s nullglob
    for m in $line; do TARGETS+=("$m"); echo "   + $m (from backup-include.conf)"; done
    shopt -u nullglob
  done < "$INCLUDE_FILE"
fi

# HIBERNATE=1 (set by vps-infra/dr/hibernate.sh before a long pause) adds the tag `hibernate`, which the
# forget below never prunes: the last state before a pause must outlive any retention window.
TAGS=(--tag "$HOSTNAME_TAG")
[[ "${HIBERNATE:-}" == 1 ]] && TAGS+=(--tag hibernate)
restic backup \
  "${TARGETS[@]}" \
  "${TAGS[@]}" \
  --host "$HOSTNAME_TAG" 2>&1

echo "-- pruning: keep 7 daily, 4 weekly, 6 monthly, and every hibernate snapshot --"
# --group-by host: restic's default groups by host AND path set, so every time a
# path is added (a new /opt/*/docker-compose.yml, a backup-include line) a fresh
# group starts and the old one keeps its 17 snapshots forever. monitoring had
# three such groups by 2026-10-02.
restic forget --host "$HOSTNAME_TAG" --group-by host \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-tag hibernate --prune

rm -rf "$STAGE"

# Heartbeat. An Uptime Kuma "Push" monitor goes DOWN when this stops arriving, so a
# backup that quietly stops working becomes visible instead of being discovered at
# restore time. Only pinged on success - reaching here means restic exited 0.
if [[ -n "${UPTIME_KUMA_PUSH_URL:-}" ]]; then
  curl -fsS --max-time 15 "${UPTIME_KUMA_PUSH_URL}?status=up&msg=OK" >/dev/null 2>&1 \
    && echo "-- pinged uptime-kuma heartbeat --" \
    || echo "  ! heartbeat ping failed (backup itself succeeded)"
fi

echo "backup.sh done on $HOSTNAME_TAG at $(date -Is)"
