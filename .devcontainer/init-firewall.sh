#!/usr/bin/env bash
# Blacklist firewall for YOLO Claude Code container.
# Default: allow all outbound. Block things that are genuinely dangerous
# for an unsupervised agent to reach from a home Mac:
#   - RFC1918 private ranges (your LAN, router admin, NAS, printers)
#   - Link-local 169.254/16 (cloud metadata endpoints)
#   - SMTP ports (anti-spam if the box gets compromised)
#
# Everything else (GitHub, npm, PyPI, Anthropic API, arbitrary HTTP) stays open.

set -euo pipefail

# Require root
if [ "$(id -u)" -ne 0 ]; then
  echo "init-firewall.sh must run as root (via sudo)." >&2
  exit 1
fi

# Reset
iptables -F
iptables -X
iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT

# Allow loopback unconditionally
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

# Allow established/related (so replies to our outbound traffic work)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS must work even if a resolver lives on a private range (common on home routers).
# Insert as first OUTPUT rule so it wins over the private-range DROPs below.
iptables -I OUTPUT 1 -p udp --dport 53 -j ACCEPT
iptables -I OUTPUT 1 -p tcp --dport 53 -j ACCEPT

# Block private/link-local ranges (LAN pivot + cloud metadata)
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
  iptables -A OUTPUT -d "$cidr" -j REJECT --reject-with icmp-net-unreachable
done

# Block outbound SMTP
for port in 25 465 587; do
  iptables -A OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset
done

echo "Firewall initialized: blacklist mode (private ranges + SMTP blocked, rest open)."

# OrbStack forwards the host ssh-agent socket as root:root 0600 — unreadable by
# the node user. chmod so the unprivileged user can connect.
if [ -S /ssh-agent ]; then
  chmod 666 /ssh-agent 2>/dev/null || true
fi
