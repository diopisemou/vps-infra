# Bachir's VPS Infrastructure

Self-contained, reproducible setup for all hosting: if a server ever gets deleted again,
you can recreate it and be back to fully configured + data restored within ~20 minutes.

## Why this exists

Last time, servers were deleted with nothing saved outside them — configuration and data
were both gone. This project fixes both halves:

- **Configuration is code**, versioned in this git repo (push it to GitHub). Any server
  can be rebuilt by running one bootstrap command with a role name.
- **Data is backed up independently** of the servers, to Cloudflare R2 (object storage,
  not tied to any VPS provider), on a schedule you control.

## Current servers

See `inventory.yml` for the live list (IP, provider, role). As of today:

| Role | Provider | IP | What runs there |
|---|---|---|---|
| main-host | Contabo VPS8 | 169.58.77.127 | Coolify — alminhaaj, FlashRide, better-openclaw, EventFlowAI, autostudio, openrevenue bundle |
| neobank | Contabo VPS6 | 169.58.79.167 | Kong, Hydra, Logto, Steel, api/auth (isolated, no PaaS) |
| meet-sso-misc | Hetzner CPX32 | 2.28.13.102 | Dokploy — Keycloak (RHSSO for alminhaaj), Jitsi Meet, room for clawexa/QueueFlowAI |
| monitoring | Contabo VPS4 | *(pending purchase)* | Uptime Kuma / Netdata parent, restic backup coordinator |

## How it works

There's no SSH-based control node (Ansible-over-SSH wasn't usable — outbound SSH is
blocked from the environment this was built in). Instead each server **pulls and runs
its own setup**:

```
curl -fsSL https://raw.githubusercontent.com/<you>/vps-infra/main/scripts/bootstrap.sh | bash -s -- <role>
```

Where `<role>` is one of: `common`, `main-host`, `neobank`, `meet-sso-misc`, `monitoring`.

`bootstrap.sh` always runs `common.sh` first (hardening + Docker), then the
role-specific script.

## Adding a new server

1. Provision the box (Hetzner/Contabo console, or however you like).
2. Add a line to `inventory.yml`.
3. SSH in (or use the provider's browser console) and run the bootstrap command above
   with the new role.
4. If it should be backed up, add it to `backup/targets.conf`.

That's the whole process — no separate onboarding steps.

## Backups

- **What**: Docker named volumes + a `pg_dump`/`mysqldump` of every database container
  found on the host, plus `/etc` and any docker-compose files under `/opt`.
- **Where**: Cloudflare R2, bucket `vps-infra-backups`, one restic repo path per server
  (`s3:https://<account-id>.r2.cloudflarestorage.com/vps-infra-backups/<hostname>`).
- **When**: configurable. Default is daily at 03:00 server-local time, keeping 7 daily /
  4 weekly / 6 monthly snapshots (restic `forget --prune`). Change the schedule by
  editing `BACKUP_SCHEDULE` in `/etc/vps-infra/backup.env` on the server (systemd
  `OnCalendar` syntax) and running `systemctl daemon-reload && systemctl restart
  restic-backup.timer`. See `backup/restic-setup.sh` for the full mechanism.
- **Credentials**: an R2 API token (S3-compatible Access Key ID + Secret) is required.
  Generate one at Cloudflare dashboard → R2 → Manage API Tokens → scoped to the
  `vps-infra-backups` bucket, then fill in `backup/r2.env` (never commit this file —
  it's in `.gitignore`).

### Restoring

```
restic -r s3:https://<account-id>.r2.cloudflarestorage.com/vps-infra-backups/<hostname> \
  --password-file /etc/vps-infra/restic-password restore latest --target /
```

Full step-by-step is in `docs/RESTORE.md`.

## Config vs data — the GitHub / R2 split

- **This repo (GitHub)**: every script, docker-compose file, and the inventory. No
  secrets. This is what makes servers *reproducible*.
- **R2**: the actual data (databases, uploaded files, volumes). This is what makes data
  *recoverable*. Restic encrypts everything client-side before it leaves the server, so
  R2 never sees plaintext.

Both are independent of every VPS provider — losing Hetzner or Contabo access entirely
still leaves both the config and the data recoverable.
