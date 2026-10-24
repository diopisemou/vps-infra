#!/usr/bin/env bash
# Install a daily timer that drops Docker BUILD CACHE older than 24 hours. Run as root on a host.
# 24h, not longer: at 5 GB of cache a day, xaalis-prod (38 GB disk) cannot hold three days of it.
#
# Why: hosts that build images on the box (xaalis-prod, monitoring's xaalis sandbox) grew their
# build cache 5-15 GB a day. xaalis-prod reached 78% of 38 GB and monitoring gained 33 GB in two
# days (2026-10-22..24). Build cache is never needed to RUN anything - only to make the next build
# faster - so pruning it cannot stop a container. Images, volumes and containers are not touched:
# rollback image tags stay, and nothing here can delete data.
set -euo pipefail
command -v docker >/dev/null || { echo "no docker on $(hostname); nothing to do"; exit 0; }

cat > /etc/systemd/system/docker-cache-prune.service <<'UNIT'
[Unit]
Description=Prune Docker build cache older than 24h (vps-infra)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker builder prune --force --filter until=24h
Nice=10
IOSchedulingClass=idle
UNIT

cat > /etc/systemd/system/docker-cache-prune.timer <<'UNIT'
[Unit]
Description=Daily Docker build-cache prune (vps-infra)

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now docker-cache-prune.timer >/dev/null
echo "$(hostname): docker-cache-prune.timer enabled, next: $(systemctl show docker-cache-prune.timer -p NextElapseUSecRealtime --value)"
