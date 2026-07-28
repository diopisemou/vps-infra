#!/usr/bin/env bash
# Rename a host durably.  Usage:  set-hostname.sh <new-hostname>
#
# Why this is more than `hostnamectl set-hostname`:
#
#   1. Contabo/Ubuntu cloud images ship `preserve_hostname: false`, so cloud-init's
#      update_hostname module runs on EVERY boot and resets the name back to the
#      provider default (vmi34xxxxx). A plain hostnamectl looks like it worked and
#      then silently reverts at the next reboot. We write a cloud.cfg.d drop-in to
#      stop that.
#   2. /etc/hosts carries a 127.0.1.1 entry with the old name. Left stale, `sudo`
#      and anything doing a reverse lookup on the local name gets slow or noisy.
#
# It matters that this is right: backup.sh tags restic snapshots with $(hostname)
# and uses it as the repo path, so a name that reverts silently splits a server's
# backup history across two paths.
set -euo pipefail

NEW="${1:-}"
if [[ -z "$NEW" ]]; then
  echo "Usage: set-hostname.sh <new-hostname>" >&2
  exit 1
fi
if ! [[ "$NEW" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "Refusing: '$NEW' is not a valid RFC-1123 hostname label." >&2
  exit 1
fi

OLD="$(hostname)"

# Renaming a Docker Swarm node orphans its node identity - the manager still lists
# the old name and services can fail to reschedule. Dokploy runs on swarm, so guard.
if docker info 2>/dev/null | grep -qE '^ Swarm: active'; then
  echo "Refusing: Docker Swarm is active on this host ($OLD)." >&2
  echo "Renaming a swarm node needs the node drained and rejoined - do it deliberately, not here." >&2
  exit 1
fi

if [[ "$OLD" == "$NEW" ]]; then
  echo "hostname is already '$NEW'"
else
  echo "-- renaming '$OLD' -> '$NEW' --"
  hostnamectl set-hostname "$NEW"
fi

echo "-- /etc/hosts --"
# Replace the 127.0.1.1 line wholesale rather than sed-ing the old name, so this
# stays correct even if the file was already partly edited.
if grep -qE '^127\.0\.1\.1' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1 ${NEW}/" /etc/hosts
else
  sed -i "1i 127.0.1.1 ${NEW}" /etc/hosts
fi
grep -E '^127\.0\.1\.1' /etc/hosts | sed 's/^/   /'

echo "-- stop cloud-init reverting it on reboot --"
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg << 'EOF'
# Managed by vps-infra. Without this, cloud-init's update_hostname module resets
# the hostname to the provider default on every boot.
preserve_hostname: true
EOF
echo "   wrote /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg"

# Pick up the new name in logs immediately instead of at next reboot.
systemctl restart rsyslog 2>/dev/null || true

echo "-- verify --"
echo "   hostname:      $(hostname)"
echo "   hostnamectl:   $(hostnamectl --static)"
echo "   preserve:      $(grep -h preserve_hostname /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg)"
echo "set-hostname.sh done: $OLD -> $(hostname)"
