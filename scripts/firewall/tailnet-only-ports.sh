#!/bin/sh
# Make container-published admin ports reachable ONLY over Tailscale: drop them on the public NIC.
#
# Why DOCKER-USER and not ufw: Docker DNATs a published port in PREROUTING and the packet then goes through
# FORWARD, so a ufw INPUT rule never sees it — deleting `ufw allow 3000` alone blocks nothing on IPv4.
# DOCKER-USER is the chain Docker reserves for exactly this and never flushes. Matching the ORIGINAL
# destination port (conntrack) survives the DNAT; matching -i <public NIC> leaves tailscale0, loopback and
# container-to-container traffic alone.
#
#   PORTS="3000" PUBLIC_IF=eth0 tailnet-only-ports.sh       (installed by the matching systemd unit)
set -eu
PORTS="${PORTS:-3000}"
PUBLIC_IF="${PUBLIC_IF:-$(ip route show default | awk '{print $5; exit}')}"
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null || continue
  "$ipt" -nL DOCKER-USER >/dev/null 2>&1 || "$ipt" -N DOCKER-USER
  for p in $PORTS; do
    set -- -i "$PUBLIC_IF" -p tcp -m conntrack --ctorigdstport "$p" --ctdir ORIGINAL -j DROP
    "$ipt" -C DOCKER-USER "$@" 2>/dev/null || "$ipt" -I DOCKER-USER 1 "$@"
    echo "$ipt: $p/tcp dropped on $PUBLIC_IF (tailnet-only)"
  done
done
