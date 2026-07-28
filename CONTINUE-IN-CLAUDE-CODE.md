# Session Handoff — Continue This in Claude Code

This file captures everything from the Cowork session that built this project, so a fresh
Claude Code session (with real terminal/SSH access) can pick up exactly where it left off.
Cowork's sandbox could not open outbound SSH (port 22) at all, and it turned out Bachir's
own Mac/network can't reach port 22 either (see "Known blocker" below) — so nothing has
actually been run on the live servers yet. That's the next job.

## Why this project exists

Bachir previously lost every server (config + data) when they were deleted with nothing
backed up outside them. This project is the fix: infrastructure as code (this repo) +
independent backups to Cloudflare R2, decoupled from any single VPS provider. See
`README.md` in this same folder for the full design.

## Current server inventory (ground truth as of this session)

| Role | Provider | IP | Status |
|---|---|---|---|
| main-host | Contabo VPS8 | 169.58.77.127 | Provisioned, **bootstrap not yet run** |
| neobank | Contabo VPS6 | 169.58.79.167 | Provisioned, **bootstrap not yet run** |
| meet-sso-misc | Hetzner CPX32 | 2.28.13.102 | Provisioned (rebuilt clean, Ubuntu 24.04), **bootstrap not yet run** |
| monitoring | Contabo VPS4 | *(not purchased yet)* | Blocked at checkout — Contabo requires a phone number Bachir hadn't supplied. Resume checkout at contabo.com when ready. |

All three live servers have Bachir's SSH public key installed:
- Hetzner: added at server creation, and again implicitly via a later rebuild
- Both Contabo boxes: added via panel → server → ⋮ → **Reset credentials** → **SSH-Key** tab

Private key lives locally at `~/Desktop/vps-ssh-keys/bachir_vps_key` (never commit this).
Both Contabo boxes also had their root **password** reset separately (for provider console
/ VNC login as a non-SSH fallback). Hetzner's root password (post-rebuild) was emailed to
Bachir by Hetzner.

## GitHub repo (canonical source scripts are pulled from)

`https://github.com/diopisemou/vps-infra` — **flat layout** (all files in repo root, no
subfolders), because it was created via GitHub's web upload UI which doesn't preserve
folder structure. `bootstrap.sh` and the role scripts fetch sibling files via
`raw.githubusercontent.com/diopisemou/vps-infra/main/<filename>`, not relative paths.

If you restructure this into proper subfolders in Claude Code (recommended — much easier
to maintain), you MUST update every `REPO_RAW_BASE`/fetch-by-filename reference in
`bootstrap.sh` and each `scripts/roles/*.sh` to match, then push, then re-verify each raw
URL resolves before trusting it against a live server.

## Cloudflare

- R2 bucket `vps-infra-backups` already created, empty, no API token wired in yet.
- Need to: Cloudflare dashboard → R2 → Manage API Tokens → create one scoped to this
  bucket → fill in `backup/r2.env` (already gitignored) on each server → run
  `backup/restic-setup.sh`.

## Known blocker: outbound SSH (port 22) times out from Bachir's Mac

Diagnosed step by step this session, all ruled out as the cause:
- Hetzner Cloud Firewall on meet-sso-misc: none applied (checked in console)
- Contabo Firewall (their newer network-level firewall feature): "You have no Firewall" (checked in panel)
- ProtonVPN / Twingate on Bachir's Mac: both disconnected
- Radio Silence (per-app firewall on the Mac): watched its live connection monitor while
  Bachir ran `ssh` — it logged 3 connection attempts from `/usr/bin/ssh` and did **not**
  block any of them
- macOS Application Firewall: on, but only filters *incoming* connections, irrelevant to
  outbound SSH

Conclusion: the block is almost certainly upstream — Bachir's router or ISP silently
dropping outbound port 22 (fairly common default on some consumer routers/ISPs as an
anti-abuse measure). Not yet fixed.

**First thing to try in Claude Code**: test whether *this* environment's outbound SSH
works at all:
```
ssh -i ~/Desktop/vps-ssh-keys/bachir_vps_key -o ConnectTimeout=8 root@2.28.13.102 echo ok
```
If Claude Code's environment can reach port 22 (likely, since it's a different network
path than Bachir's home connection), just proceed with SSH-based automation directly —
no need for the browser-console workaround below.

If it still times out even from here, fall back to: have Bachir open each provider's
browser console (Hetzner: console.hetzner.com → server → `>_` icon top right; Contabo:
new.contabo.com/servers/vps → server → console/VNC option) and paste the bootstrap
command there himself, since that path goes over HTTPS and is unaffected by the port-22
issue. Or have him test from a phone hotspot to confirm/rule out the router theory.

## Bootstrap usage

```
curl -fsSL https://raw.githubusercontent.com/diopisemou/vps-infra/main/bootstrap.sh | bash -s -- <role>
```

Roles: `common` (runs automatically first, always — hardening + Docker), `main-host`,
`neobank`, `meet-sso-misc`, `monitoring`.

## What's left to do, in rough order

1. **Get real terminal/SSH access working** (see blocker above) — this unblocks everything else.
2. Run bootstrap on all three live servers with their respective roles.
3. Purchase the 4th server (Contabo VPS4, monitoring) — needs Bachir to supply a phone
   number at checkout, was left pending.
4. Generate a Cloudflare R2 API token and wire it into `/etc/vps-infra/r2.env` on each
   server, then run `backup/restic-setup.sh` on each to activate the backup timer.
5. On meet-sso-misc: log into Dokploy (`https://2.28.13.102:3000`), import
   `compose/keycloak-compose.yml` and `compose/jitsi-compose.yml` as Dokploy apps, point
   DNS `keycloak.alminhaaj.info` and `meet.alminhaaj.info` at `2.28.13.102`.
6. On main-host: set up Coolify apps for alminhaaj, FlashRide, better-openclaw,
   EventFlowAI, autostudio, and the openrevenue bundle.
7. On neobank: fill in real secrets/DSNs into `/opt/neobank/docker-compose.yml`
   (`compose/neobank-compose.yml` is the template) — copy from the existing
   bidewpay.com config, which Bachir has separately.
8. Once monitoring server exists: run its bootstrap role, add Uptime Kuma monitors for
   every other host.
9. End to end restore drill: intentionally test `docs/RESTORE.md` against one server to
   prove the whole backup/restore loop actually works before relying on it.

## Instructions for setting this up in Claude Code

1. In this same folder (or wherever you want to work), this project is already git-
   initialized locally. You can also `git clone https://github.com/diopisemou/vps-infra.git`
   fresh if you'd rather work from the canonical flat-layout source.
2. Grant Claude Code shell/terminal and network access (Cowork's sandbox explicitly could
   not do outbound SSH — that restriction does not necessarily apply to Claude Code's
   environment, so re-test rather than assuming it's still blocked).
3. Make the private key available to the environment: either point at
   `~/Desktop/vps-ssh-keys/bachir_vps_key` directly (if running locally on Bachir's own
   Mac) or have Bachir paste its contents somewhere Claude Code can read once, then treat
   it as a secret (never print it back, never commit it).
4. Verify connectivity first (see the `ssh ... echo ok` test above) before attempting any
   automation — don't assume the port-22 block is fixed.
5. Once SSH works, you can drive bootstrap remotely, e.g.:
   ```
   ssh -i ~/Desktop/vps-ssh-keys/bachir_vps_key root@169.58.77.127 \
     'curl -fsSL https://raw.githubusercontent.com/diopisemou/vps-infra/main/bootstrap.sh | bash -s -- main-host'
   ```
   Repeat per server with its correct role and IP from the inventory table above.
6. Work through the "What's left to do" list in order. Update `inventory.yml` and this
   file as things change (new servers, new IPs, roles completed) so the next session has
   accurate ground truth too.
7. Never commit secrets to this repo (it's public on GitHub): no passwords, no private
   key contents, no R2 tokens. `backup/r2.env` and `.ssh/` are already gitignored — keep
   it that way.
