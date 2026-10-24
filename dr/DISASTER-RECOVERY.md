# Disaster recovery — Bidew

**Goal:** nothing is ever rebuilt from scratch again. April–July 2026 the servers went unpaid and were deleted
with everything on them. Since 2026-10-24 every machine is backed up off-site nightly, the backups are proven
restorable every month, and the keys to open them live somewhere that is not a server.

## What is protected

| Machine | When | What | Kept |
|---|---|---|---|
| **mac-main** (`dr/mac-backup.sh`, LaunchAgent `io.bidew.dr-backup`) | 02:30 nightly (on wake if asleep) | every repo under `~/Developer` as its full `.git` (all branches, tags, stashes, **unpushed commits**) + uncommitted/untracked files + ignored secret files (`.env*`, keys, keystores); Second Brain vault; Paperclip (latest hourly DB dump, companies, skills); agentmemory; `~/.ssh`; `~/.config/bidew`; Claude memory + skills; fleet `data/*.json` + `.claude/skills`; LaunchAgents; Brewfile | 14 daily, 8 weekly, 24 monthly |
| **spare-01, main-host, monitoring, neobank, meet-sso-misc, xaalis-prod** (`backup/backup.sh`, systemd `restic-backup.timer`) | ~03:00 nightly | `pg_dumpall` / `mysqldump` of every database container (detected by engine, not image name), consistent SQLite copies (`pre-backup.d/sqlite-snapshots.sh`), every Docker volume (except re-downloadable caches: Ollama models, docker-in-docker layers), `/etc/vps-infra`, Coolify/Dokploy control plane, `/opt/*/docker-compose.yml`, host extras in `/etc/vps-infra/backup-include.conf` | 7 daily, 4 weekly, 6 monthly |
| **Any snapshot tagged `hibernate`** | made by `dr/hibernate.sh` | the last state before a pause | **forever** |

All of it goes to one place: Cloudflare R2 bucket `vps-infra-backups`, one encrypted restic repository per
machine (`.../vps-infra-backups/<host>`), one shared passphrase.

Each backup writes `dumps/MANIFEST` (every database found and whether its dump worked) and
`dumps/SKIPPED-VOLUMES`, so a drill can tell "this host runs no databases" from "the dump silently failed".

## The recovery kit — without it nothing below works

Five values open every backup: `R2_ACCOUNT_ID`, `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
`RESTIC_PASSWORD`. They exist in:

1. `/etc/vps-infra/r2.env` on each server — **gone if the servers are gone**
2. `~/.config/bidew/backup.env` on the Mac (0600; agents are refused by the fleet guard) — **gone if the Mac is gone**
3. Infisical project **`bidew-dr`**, env `prod` — put there by `python3 -I dr/escrow.py` (Owner-run; no machine identity is a member)
4. **Your password manager**, secure note "Bidew backup recovery kit" — from `python3 -I dr/escrow.py --show-kit`

3 and 4 are the ones that survive a disaster. Keep both. A restic repository whose passphrase is lost is
unrecoverable — nobody, including Cloudflare, can open it.

## Keep alive while paused (cheap or free; everything else can be cancelled)

- **Cloudflare account** — R2 holds every backup; DNS for bidew.io. R2 is free to 10 GB, $0.015/GB-month above.
- **Domain renewals** — auto-renew ON for bidew.io and every product domain. A lapsed domain loses mail and
  every account that logs in with it.
- **GitHub** (code), **Infisical** (secrets + `bidew-dr`), **Google Workspace** if mail must keep working.

## Checks that run by themselves (Mac LaunchAgents → macOS notification on failure)

- `io.bidew.dr-status` — Mondays 09:15: every machine's newest snapshot, read **from R2** (a dead server cannot
  report on itself); fails if any is older than 36 h. Hosts paused on purpose go in `~/.local/bidew/dr-paused`.
- `io.bidew.dr-drill` — 1st of each month 04:00: opens every repository with the kit alone, re-reads 3% of the
  data, restores and checks every database dump (completion marker, SQLite `integrity_check`), restores two
  Mac repos and runs `git fsck`.
- Logs: `~/.local/bidew/logs/dr-{backup,status,drill}.log`. Run any by hand: `dr/status.sh`, `dr/drill.sh [host]`.
- The servers also ping an Uptime Kuma push monitor (on `monitoring`) after each good backup.

## A. Before a pause (stopping servers, not paying for a while)

```bash
cd ~/Developer/vps-infra && dr/hibernate.sh
```

Backs up every server and the Mac **now**, tags each snapshot `hibernate`, proves each one from R2, and writes
`Second Brain/30-projects/Hibernation <date>.md`. **Cancel nothing until it prints `ALL GREEN`.** Then add the
cancelled hosts to `~/.local/bidew/dr-paused` so the Monday check does not nag about them.

## B. Restore after a pause / all servers lost

You need: the recovery kit, a Mac (or any Linux box) with `restic`, and new VPSes.

1. **Get the kit onto the machine you restore from** (Mac: `~/.config/bidew/backup.env`, mode 600, the five
   `KEY='value'` lines). Check it: `dr/status.sh` must list every host.
2. **Pick the snapshot.** `. dr/lib.sh; dr_repo <old-host>; restic snapshots` — the `hibernate` one, or the newest.
3. **New server:** create it, run `scripts/bootstrap.sh` + the role script, put the kit in `/etc/vps-infra/r2.env`,
   run `backup/restic-setup.sh` (this reinstalls the nightly backup — **set `HOSTNAME_TAG=<old-host>` in
   `/etc/vps-infra/backup.env` first** so it keeps writing to the same repository).
4. **Restore into a scratch dir, never straight over `/`:**
   `restic -r s3:https://<acct>.r2.cloudflarestorage.com/<bucket>/<old-host> restore <snapshot> --target /var/backups/restore`
5. From `/var/backups/restore`:
   - `etc/vps-infra/` → `/etc/vps-infra/`; `opt/*` → `/opt/`; `data/coolify` → `/data/coolify` (holds Coolify's
     `APP_KEY` — **restore it before the Coolify DB**, or its stored credentials cannot be decrypted).
   - Databases: start each stack's database container empty, then
     `docker exec -i <db-container> psql -U <user> < var/backups/vps-infra-stage/dumps/<container>.sql`
     (MySQL: `mysql -uroot -p`).
   - SQLite (`dumps/sqlite/<volume>/<path>`): stop the app, copy the file into the volume at `<path>`, delete any
     `-wal`/`-shm` next to it, start the app. **The Bidew hub** = volume `bidew_hubdata`, file `bidew.sqlite`.
   - Other volumes: `docker run --rm -v <volume>:/to -v /var/backups/restore/var/backups/vps-infra-stage/volumes:/from alpine sh -c "cd /to && tar xf /from/<volume>.tar"`
     (snapshots before 2026-10-24 hold `<volume>.tar.gz` → `tar xzf`).
   - Volumes listed in `dumps/SKIPPED-VOLUMES` were caches: re-pull them (e.g. `ollama pull <model>`).
6. `docker compose up -d` per stack; for Coolify apps, redeploy from the Coolify UI. Re-point DNS in Cloudflare if
   the IP changed. The Bidew hub: `scripts/deploy-vps.sh root@<new-host>` from the bidew-ai repo after the volume
   is restored.
7. Run `dr/drill.sh <old-host>` and `dr/status.sh` — then remove the host from `dr-paused`.

## C. The Mac is lost or wiped

1. New Mac: Homebrew, then `brew install restic`; create `~/.config/bidew/backup.env` from the kit.
2. `git clone https://github.com/diopisemou/vps-infra ~/Developer/vps-infra` (or download `dr/` from GitHub).
3. `. ~/Developer/vps-infra/dr/lib.sh; dr_repo mac-main; restic restore latest --host mac-main --target /`
   — files return to their original paths under `/Users/bachirdiop` (restore to a scratch `--target` first if the
   user name differs, then move).
4. **Repos come back as `.git` + your uncommitted work only.** Bring back the unchanged tracked files without
   touching the restored edits, in each repo:
   `git ls-files -d -z | xargs -0 git checkout --` — then `git status`, `git stash list`, `git log --branches --not --remotes`
   (your unpushed commits) should all look as they did.
5. `brew bundle --file <restored Brewfile>`; `scripts/install-launchd.sh` in bidew-ai; `dr/install-mac-backup.sh`;
   Paperclip: start it, then load the restored `paperclip-*.sql.gz` into its database.

## D. One server lost, others fine

Same as B for that host only. Nothing else changes.

## Known limits (be honest about these)

- **R2 is the only off-site copy.** One provider, one account. A second independent copy is worth adding: a
  Time Machine / external SSD on the Mac (Time Machine is **not** configured today), or Backblaze B2 (free 10 GB,
  no card) via `restic copy`.
- **Unpushed code is safe in R2, not on GitHub.** ~900 commits were Mac-only on 2026-10-24. The fleet's pushes
  wait in the approval queue; approving them is the best second copy for code.
- **Bucket size.** The 2026-10-24 switch to uncompressed volume tars re-uploaded spare-01's volumes once (+7.4 GB,
  mostly Ollama models now excluded). It ages out with the 6-month retention; until then R2 is ~17 GB (≈ $0.11/month).
- **The restic passphrase is short** (10 characters). Rotating it is `restic key add` + `key remove` on all seven
  repositories plus every `r2.env` — worth doing together with the escrow.
