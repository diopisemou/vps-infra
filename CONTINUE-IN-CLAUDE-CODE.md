# Session Handoff

Updated 2026-07-28 in Claude Code, which has real terminal access. The previous version
of this file was written from Cowork's sandbox and contained several assumptions that
turned out to be wrong when checked against the live servers. Corrections are marked.

## Why this project exists

Bachir previously lost every server (config + data) when they were deleted with nothing
backed up outside them. This project is the fix: infrastructure as code (this repo) +
independent backups to Cloudflare R2, decoupled from any single VPS provider. See
`README.md` for the full design.

## Server inventory (verified by port-probe 2026-07-28)

| Role | Provider | IP | Actually observed |
|---|---|---|---|
| main-host | Contabo VPS8 | 169.58.77.127 | **Coolify already installed** — Traefik on 443 (503), Coolify UI on 8000, 6001/6002 open. Bootstrap not run. |
| neobank | Contabo VPS6 | 169.58.79.167 | Genuinely empty, nothing listening. Bootstrap not run. |
| meet-sso-misc | Hetzner CPX32 | 2.28.13.102 | **Dokploy already installed and serving** on :3000 (HTTP 200), Traefik on 443 (404). Bootstrap not run. |
| monitoring | Contabo VPS4 | 169.58.85.228 | Purchased and bootstrapped. Uptime Kuma healthy on :3001, monitors not yet added. |

> ~~Correction:~~ the old file said meet-sso-misc was "rebuilt clean" and that no server
> had anything on it. Both PaaS installs are already there. Anything that reconfigures
> those boxes has to preserve the PaaS admin ports, because they are currently the only
> reachable way in.

All three have Bachir's SSH public key installed. Private key: `~/Desktop/vps-ssh-keys/bachir_vps_key`
(never commit). Both Contabo boxes also have a root password set for VNC console access;
Hetzner's was emailed after the rebuild. **Console access is the fallback and is not
affected by the port-22 problem below** — `PasswordAuthentication no` only applies to sshd.

## The port-22 blocker — diagnosed, confirmed, not yet worked around

Outbound from Bachir's Mac:

| Port | Result |
|---|---|
| 22, 80, 53 | blocked (timeout) |
| 443, 3000, 8000, 6001, 6002 | fine |

Proof it is the network and not the servers or the tooling:
- `github.com:22` and `example.com:80` also time out — nothing to do with these VPSes
- identical results with Claude Code's sandbox **on and off**, so not a sandbox artifact
- blocking exactly 22/80/53 while leaving high ports alone is a textbook residential ISP
  anti-abuse filter

Everything the old file ruled out (Hetzner/Contabo firewalls, ProtonVPN, Twingate, Radio
Silence, macOS firewall) stays ruled out. It is the router/ISP.

**Chosen workaround: Tailscale on every host.** SSH then runs over the tailnet instead of
public port 22, which also gets SSH off the public internet entirely. Tailscale falls back
to DERP relaying over 443 if UDP is blocked, so it works on this connection regardless.
`common.sh` now installs it, and adds `ufw allow in on tailscale0`.

## What changed in the scripts this session

Every one of these was a live bug that would have bitten on first run:

- **`common.sh` firewall would have locked us out.** It opened only 22/80/443 — cutting
  off Coolify (8000/6001/6002) and Dokploy (3000), the only working paths in. Now detects
  which PaaS is present and keeps its ports open, plus trusts `tailscale0`.
- **`neobank.sh` ran `ufw --force reset`**, wiping the tailnet rule `common.sh` had just
  added. Rules are additive now.
- **Compose files were never actually copied.** Both role scripts resolved them via
  `$BASH_SOURCE`, which is meaningless when the script is piped from `curl` — and the
  failure was swallowed by `|| true`. Now fetched from `REPO_RAW_BASE`.
- **`backup.sh` would fail entirely on a host with no stacks**: an unmatched
  `/opt/*/docker-compose.yml` glob got passed to restic literally. Also `[[ -f x ]] && source x`
  aborts under `set -e` when the file is absent, and missing R2 values built a malformed
  repo URL instead of erroring clearly.
- **`monitoring.sh`'s `docker run --name` was not idempotent** and 3001 was never opened.
- **Ordering bugs in `common.sh`**: the SSH key was authorized *after* the deploy user
  copied it, and docker was installed *after* adding deploy to the `docker` group.
- **`inventory.yml` claimed `backed_up: true` on all three servers.** No backups exist
  anywhere. That field now means "timer active AND restore verified" and is false.

## Biggest remaining risk: the restic passphrase

`RESTIC_PASSWORD` encrypts the backups. Restic has no recovery path — lose it and every
snapshot in R2 is permanently unreadable. If its only copy lives on the servers being
backed up, then losing the servers loses the backups too, which is precisely the disaster
this repo exists to prevent. **Store it in a password manager plus one offline copy before
filling in `r2.env`**, and use the same passphrase on every host.

## Repo layout

Local uses proper subfolders (`scripts/`, `backup/`, `compose/`, `docs/`). GitHub
`diopisemou/vps-infra` still has the old **flat** layout from the web-upload UI, and the
two have unrelated git histories. The fixed scripts must be pushed before any server can
fetch them, since `bootstrap.sh` pulls siblings from
`raw.githubusercontent.com/diopisemou/vps-infra/main/scripts/roles/<role>.sh`.

There is also a stray duplicate clone at `vps-infra/vps-infra/` — now gitignored, safe to
delete once confirmed unneeded.

## Hostnames

All four hosts now carry their real names (`main-host`, `neobank`, `meet-sso-misc`,
`monitoring`) instead of Contabo's `vmi34xxxxx` defaults. Use `scripts/set-hostname.sh`,
not a bare `hostnamectl` — these images set `preserve_hostname: false`, so cloud-init
resets the name on every boot unless a drop-in stops it. The name is what `backup.sh`
uses as the restic tag and repo path, so a silent revert would split a server's backup
history across two paths.

`meet-sso-misc` runs Dokploy on Docker Swarm, where the node identity *is* the hostname.
It was already named correctly; `set-hostname.sh` refuses to run on a swarm node anyway.
Coolify was safe to rename — it points at `host.docker.internal`, not the OS hostname.

## Bootstrap usage

```
curl -fsSL https://raw.githubusercontent.com/diopisemou/vps-infra/main/scripts/bootstrap.sh | bash -s -- <role>
```

Roles: `common` (always runs first), `main-host`, `neobank`, `meet-sso-misc`, `monitoring`.

## What's left, in order

1. Push the fixed scripts to GitHub (needed before any server can fetch them).
2. Install Tailscale on the Mac, log in, then paste the join command in each provider
   console. **Do `neobank` first** — it is empty, so a mistake there costs nothing.
3. Bootstrap all three servers over the tailnet with their roles.
4. Save `RESTIC_PASSWORD` off-server, create the R2 API token, fill `/etc/vps-infra/r2.env`
   on each host, run `backup/restic-setup.sh`.
6. meet-sso-misc: import the Keycloak + Jitsi compose files in Dokploy, point DNS
   `keycloak.alminhaaj.info` / `meet.alminhaaj.info` at 2.28.13.102.
7. main-host: Coolify apps for alminhaaj, FlashRide, better-openclaw, EventFlowAI,
   autostudio, openrevenue bundle.
8. neobank: fill real secrets/DSNs into `/opt/neobank/docker-compose.yml` from the
   existing bidewpay.com config.
9. monitoring: add Uptime Kuma monitors for the other three hosts (box is bootstrapped).
10. **Do the restore drill** — verify `docs/RESTORE.md` end to end against one server
    before trusting any of this. Until that passes, `backed_up` stays false.

## Rules

- Never commit secrets — the repo is public. No passwords, private keys, or R2 tokens.
  `backup/r2.env` and `**/*.env` are gitignored; keep it that way.
- Keep `inventory.yml` and this file matching reality. The last handoff drifted and cost
  a session's worth of wrong assumptions.
