#!/usr/bin/env python3
"""Print every server in inventory.yml as "<hostname> <ip>", one per line.

inventory.yml is the single source of truth for what exists. fleet-status.sh and
kuma-provision.py used to carry their own hand-copied host lists, so adding a
server meant editing four files and one was always missed. Both read this now.

No PyYAML needed: it only reads the `- hostname:` / `ip:` pairs under `servers:`.
"""
import re
import sys
from pathlib import Path

INVENTORY = Path(__file__).resolve().parent.parent / "inventory.yml"


def hosts(path: Path = INVENTORY) -> list[tuple[str, str]]:
    out, name, in_servers = [], None, False
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\S", line):              # a top-level key starts/ends the block
            in_servers = line.startswith("servers:")
            continue
        if not in_servers:
            continue
        m = re.match(r"^  - hostname:\s*(\S+)", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"^    ip:\s*([0-9.]+)", line)
        if m and name:
            out.append((name, m.group(1)))
            name = None
    return out


if __name__ == "__main__":
    found = hosts()
    if not found:
        sys.exit(f"no servers found in {INVENTORY}")
    for n, ip in found:
        print(n, ip)
