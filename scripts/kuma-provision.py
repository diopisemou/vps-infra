#!/usr/bin/env python3
"""
Provision Uptime Kuma monitors for the vps-infra fleet.

Run this YOURSELF - it prompts for your Kuma password locally and never prints or
transmits it anywhere except to your own Kuma instance.

    pip3 install uptime-kuma-api
    python3 scripts/kuma-provision.py

Prerequisite: create the admin account first at http://169.58.85.228:3001/setup

Idempotent: monitors are matched by name, so re-running updates rather than
duplicating. At the end it prints the push URLs for the backup heartbeat monitors -
paste those back and they get wired into /etc/vps-infra/backup.env on each host.
"""
import inspect
import sys
from getpass import getpass

try:
    from uptime_kuma_api import UptimeKumaApi, MonitorType
except ImportError:
    sys.exit("Missing dependency. Run:  pip3 install uptime-kuma-api")

# uptime-kuma-api renames fields between versions (e.g. retries -> maxretries).
# Check every keyword up front, so a typo fails before anything is created rather
# than halfway through the fleet.
_VALID_KEYS = {
    p for p in inspect.signature(UptimeKumaApi._build_monitor_data).parameters
    if p != "self"
}


def check_keys(**kw):
    bad = set(kw) - _VALID_KEYS
    if bad:
        sys.exit(
            f"Unsupported monitor field(s) for uptime-kuma-api here: {sorted(bad)}\n"
            f"Valid fields include: {sorted(k for k in _VALID_KEYS if len(k) < 20)}"
        )
    return kw

KUMA_URL = "http://169.58.85.228:3001"

# hostname -> (ip, [extra http checks as (label, url)])
HOSTS = {
    "main-host":     ("169.58.77.127", [("coolify-ui", "http://169.58.77.127:8000")]),
    "neobank":       ("169.58.79.167", []),
    "meet-sso-misc": ("2.28.13.102",   [("dokploy-ui", "http://2.28.13.102:3000")]),
    "monitoring":    ("169.58.85.228", []),
    "spare-01":      ("169.58.97.123", []),
}

# Backups run daily with up to 30min jitter, so allow 25h before calling it down.
BACKUP_HEARTBEAT_INTERVAL = 90000


def upsert(api, existing, **kw):
    """Create a monitor, or update it if one with that name already exists."""
    name = kw["name"]
    if name in existing:
        api.edit_monitor(existing[name], **kw)
        print(f"  updated  {name}")
        return existing[name]
    mid = api.add_monitor(**kw)["monitorID"]
    print(f"  created  {name}")
    return mid


def main():
    print(f"Connecting to {KUMA_URL}")
    username = input("Kuma username: ").strip()
    password = getpass("Kuma password (not echoed): ")

    api = UptimeKumaApi(KUMA_URL)
    try:
        api.login(username, password)
    except Exception as e:
        sys.exit(f"Login failed: {e}\nCreate the admin account at {KUMA_URL}/setup first.")

    existing = {m["name"]: m["id"] for m in api.get_monitors()}
    push_tokens = {}

    for host, (ip, https) in HOSTS.items():
        print(f"\n{host} ({ip})")

        upsert(api, existing, **check_keys(
            type=MonitorType.PING, name=f"{host} ping",
            hostname=ip, interval=60, maxretries=2))

        upsert(api, existing, **check_keys(
            type=MonitorType.PORT, name=f"{host} ssh",
            hostname=ip, port=22, interval=300, maxretries=2))

        for label, url in https:
            upsert(api, existing, **check_keys(
                type=MonitorType.HTTP, name=f"{host} {label}",
                url=url, interval=120, maxretries=2,
                accepted_statuscodes=["200-299", "300-399"]))

        # Push monitor: backup.sh pings this on success. No ping for 25h => DOWN.
        name = f"{host} backup"
        mid = upsert(api, existing, **check_keys(
            type=MonitorType.PUSH, name=name,
            interval=BACKUP_HEARTBEAT_INTERVAL, maxretries=0))
        token = api.get_monitor(mid).get("pushToken")
        if token:
            push_tokens[host] = token
        else:
            print(f"  !! no pushToken returned for {name}; read it from the UI")

    print("\n" + "=" * 68)
    print("Backup heartbeat push URLs - give these to Claude to wire in, or run")
    print("the matching command yourself on each host:")
    print("=" * 68)
    for host, token in push_tokens.items():
        print(f"{host:15} {KUMA_URL}/api/push/{token}")

    api.disconnect()
    print("\nDone. Monitors are live in the Kuma dashboard.")


if __name__ == "__main__":
    main()
