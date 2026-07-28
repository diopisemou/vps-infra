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
for cid in $(docker ps --format '{{.ID}} {{.Image}}' | awk '{print $1}'); do
  image=$(docker inspect --format '{{.Config.Image}}' "$cid")
  name=$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')
  case "$image" in
    postgres*|*postgres*)
      user=$(docker exec "$cid" printenv POSTGRES_USER 2>/dev/null || echo postgres)
      docker exec "$cid" pg_dumpall -U "$user" > "$STAGE/dumps/${name}.sql" 2>/dev/null || \
        echo "  ! pg_dumpall failed for $name (skipping)"
      ;;
    mysql*|mariadb*)
      pass=$(docker exec "$cid" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
      docker exec "$cid" sh -c "mysqldump -uroot -p'$pass' --all-databases" > "$STAGE/dumps/${name}.sql" 2>/dev/null || \
        echo "  ! mysqldump failed for $name (skipping)"
      ;;
  esac
done

echo "-- snapshotting named docker volumes --"
for vol in $(docker volume ls -q); do
  docker run --rm -v "${vol}:/from" -v "$STAGE/volumes:/to" alpine \
    sh -c "tar -C /from -czf /to/${vol}.tar.gz . 2>/dev/null || true"
done

echo "-- init restic repo if needed --"
restic snapshots >/dev/null 2>&1 || restic init

echo "-- backing up: dumps, volume snapshots, compose files, /etc/vps-infra --"
# An unmatched /opt/*/docker-compose.yml glob would be passed through literally and
# make restic error out, failing the whole backup on a host that has no stacks yet.
TARGETS=("$STAGE/dumps" "$STAGE/volumes" /etc/vps-infra)
shopt -s nullglob
for f in /opt/*/docker-compose.yml; do TARGETS+=("$f"); done
shopt -u nullglob

restic backup \
  "${TARGETS[@]}" \
  --tag "$HOSTNAME_TAG" \
  --host "$HOSTNAME_TAG" 2>&1

echo "-- pruning: keep 7 daily, 4 weekly, 6 monthly --"
restic forget --host "$HOSTNAME_TAG" \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

rm -rf "$STAGE"
echo "backup.sh done on $HOSTNAME_TAG at $(date -Is)"
