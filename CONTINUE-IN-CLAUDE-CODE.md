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
| main-host | Contabo VPS8 | 169.58.77.127 | Bootstrapped. Coolify (pre-existing, installer skipped), 6 containers healthy, UI on 8000. |
| neobank | Contabo VPS6 | 169.58.79.167 | Bootstrapped. Empty by design — compose template staged, needs real secrets. |
| meet-sso-misc | Hetzner CPX32 | 2.28.13.102 | Bootstrapped. Dokploy (pre-existing, installer skipped) on :3000, 3 containers up. |
| monitoring | Contabo VPS4 | 169.58.85.228 | Purchased and bootstrapped. Uptime Kuma healthy on :3001, monitors not yet added. |

> ~~Correction:~~ the old file said meet-sso-misc was "rebuilt clean" and that no server
> had anything on it. Both PaaS installs were already there, and the old bootstrap had in
> fact already been run on both. Anything reconfiguring those boxes must preserve the PaaS
> admin ports.

All four have Bachir's SSH public key installed. Private key: `~/Desktop/vps-ssh-keys/bachir_vps_key`
(never commit). Both Contabo boxes also have a root password set for VNC console access;
Hetzner's was emailed after the rebuild. **Console access is the fallback and is not
affected by the port-22 problem below** — `PasswordAuthentication no` only applies to sshd.

## The port-22 blocker — RESOLVED via Tailscale

**Status: solved.** Tailscale is logged in on main-host, neobank, meet-sso-misc and
monitoring, and SSH over the tailnet is verified from the Mac — including MagicDNS, so
`ssh root@main-host` just works regardless of which network Bachir is on. The home
ISP block no longer gates anything.

Tailnet: `tailfa2c11.ts.net`

| Host | Tailnet IP |
|---|---|
| main-host | 100.77.25.32 |
| neobank | 100.126.238.23 |
| meet-sso-misc | 100.106.100.27 |
| monitoring | 100.98.254.79 |
| spare-01 | **not joined yet** — run `tailscale up --hostname=spare-01` |

The underlying home-network block still exists and is described below for reference.

Outbound from Bachir's Mac, on the home network:

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
to DERP relaying over 443 if UDP is blocked, so it works on that connection regardless.
`common.sh` installs it and adds `ufw allow in on tailscale0`. Done on four of five hosts.

**Important:** `ufw allow in on tailscale0` does NOT restrict published Docker ports.
Docker inserts its own iptables rules ahead of ufw's chain, so a container published
with `-p 3001:3001` is reachable from the internet whatever ufw says. To bind a
container to the tailnet you must publish on the tailnet address itself
(`-p <tailnet-ip>:3001:3001`), which is what `monitoring.sh` now does.

## What changed in the scripts this session

Every one of these was a live bug that would have bitten on first run:

- **`common.sh` firewall would have locked us out.** It opened only 22/80/443 — cutting
  off Coolify (8000/6001/6002) and Dokploy (3000), the only working paths in. Now detects
  which PaaS is present and keeps its ports open, plus trusts `tailscale0`.
- **`neobank.sh` ran `ufw --force reset`**, wiping the tailnet rule `common.sh` had just
  added. Rules are additive now.
- **Compose files resolved via `$BASH_SOURCE`**, which is meaningless when the script is
  piped from `curl`, with the failure swallowed by `|| true`. (In practice the files were
  already present on meet-sso-misc, so this had not yet bitten — but it would have on any
  fresh host using the documented curl invocation.) Now fetched from `REPO_RAW_BASE`.
- **`backup.sh` would fail entirely on a host with no stacks**: an unmatched
  `/opt/*/docker-compose.yml` glob got passed to restic literally. Also `[[ -f x ]] && source x`
  aborts under `set -e` when the file is absent, and missing R2 values built a malformed
  repo URL instead of erroring clearly.
- **`monitoring.sh`'s `docker run --name` was not idempotent** and 3001 was never opened.
- **Ordering bugs in `common.sh`**: the SSH key was authorized *after* the deploy user
  copied it, and docker was installed *after* adding deploy to the `docker` group.
- **`inventory.yml` claimed `backed_up: true` on all three servers.** No backups exist
  anywhere. That field now means "timer active AND restore verified" and is false.
- **sshd hardening silently did nothing on all three Contabo boxes.** Their images ship
  `/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication yes`; sshd keeps
  the *first* value it obtains and the `Include` sits at line 12, so the edit at line 66
  never took effect. Password auth was live on three public IPs while the script reported
  success. Now written as a `00-vps-infra.conf` drop-in and verified with `sshd -T`.

## Biggest remaining risk: the restic passphrase

`RESTIC_PASSWORD` encrypts the backups. Restic has no recovery path — lose it and every
snapshot in R2 is permanently unreadable. If its only copy lives on the servers being
backed up, then losing the servers loses the backups too, which is precisely the disaster
this repo exists to prevent. **Store it in a password manager plus one offline copy before
filling in `r2.env`**, and use the same passphrase on every host.

## Repo layout

Subfolders (`scripts/`, `backup/`, `compose/`, `docs/`), on GitHub and locally — the old
flat web-upload layout was replaced. `bootstrap.sh` pulls siblings from
`raw.githubusercontent.com/diopisemou/vps-infra/main/scripts/roles/<role>.sh`.

**`raw.githubusercontent.com` caches for 5 minutes** (`max-age=300`). Pushing a fix and
immediately re-running bootstrap silently executes the OLD script — this happened once
this session and produced a confusing result. Verify the served content before trusting a
run, or pipe the local file over SSH instead:
`ssh root@host bash -s -- <args> < scripts/foo.sh`.

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

1. **Backups — the whole point of this repo, and still entirely undone.** Save
   `RESTIC_PASSWORD` off-server first, create the Cloudflare R2 API token, fill
   `/etc/vps-infra/r2.env` on each host, run `backup/restic-setup.sh`. Nothing is backed
   up until this is done; restic is not even installed yet.
2. Install Tailscale on the Mac and run `tailscale up --hostname=<name>` on each of the
   four hosts, so access does not depend on being tethered.
3. meet-sso-misc: import the Keycloak + Jitsi compose files in Dokploy, point DNS
   `keycloak.alminhaaj.info` / `meet.alminhaaj.info` at 2.28.13.102.
4. main-host: Coolify apps for alminhaaj, FlashRide, better-openclaw, EventFlowAI,
   autostudio, openrevenue bundle.
5. neobank: fill real secrets/DSNs into `/opt/neobank/docker-compose.yml` from the
   existing bidewpay.com config.
6. monitoring: add Uptime Kuma monitors for the other three hosts (box is bootstrapped).
7. **Do the restore drill** — verify `docs/RESTORE.md` end to end against one server
    before trusting any of this. Until that passes, `backed_up` stays false.

## Rules

- Never commit secrets — the repo is public. No passwords, private keys, or R2 tokens.
  `backup/r2.env` and `**/*.env` are gitignored; keep it that way.
- Keep `inventory.yml` and this file matching reality. The last handoff drifted and cost
  a session's worth of wrong assumptions.
