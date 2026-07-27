# Restoring a server from backup

Scenario: a server was deleted (or you're standing up a replacement) and you need its
data back.

1. Provision a fresh box, same OS (Ubuntu 24.04+).
2. Run the bootstrap for its role, e.g.:
   ```
   curl -fsSL https://raw.githubusercontent.com/<you>/vps-infra/main/scripts/bootstrap.sh | bash -s -- main-host
   ```
   This gets Docker + Coolify/Dokploy/whatever the role needs installed and running,
   but with empty data.
3. Install restic and set credentials:
   ```
   apt-get install -y restic
   cp backup/r2.env.example /etc/vps-infra/r2.env   # then fill in the real values
   source /etc/vps-infra/r2.env
   export RESTIC_REPOSITORY="s3:https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/<old-hostname>"
   export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
   export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
   export RESTIC_PASSWORD
   ```
   Note: use the **old** hostname in the repository path (that's how snapshots are
   namespaced per-server) even though you're restoring onto a new box.
4. List what's available:
   ```
   restic snapshots
   ```
5. Restore into a scratch directory first (never restore straight over a live system):
   ```
   restic restore latest --target /var/backups/restore-test
   ```
6. From `/var/backups/restore-test`, you'll find:
   - `dumps/*.sql` — database dumps, restore with `psql < file.sql` or `mysql < file.sql`
     into the freshly-started DB containers from the role's docker-compose.
   - `volumes/*.tar.gz` — one per docker named volume, restore with:
     ```
     docker run --rm -v <volume-name>:/to -v /var/backups/restore-test/volumes:/from \
       alpine sh -c "cd /to && tar xzf /from/<volume-name>.tar.gz"
     ```
   - `opt/*/docker-compose.yml` — the exact compose files that were running; diff
     against what bootstrap installed and reconcile any drift.
7. Once data is back and containers are healthy, re-point DNS if the IP changed.
