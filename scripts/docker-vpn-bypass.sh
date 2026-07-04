#!/usr/bin/env bash
# Keeps Docker's bridge networks routing straight out over the LAN,
# bypassing whatever default route the local Surfshark client installs.
# Without this, gluetun's own VPN tunnel gets nested inside the local
# VPN tunnel (double-VPN), which is what breaks Prowlarr/qbittorrent
# when the local VPN is connected.
set -euo pipefail

TABLE=100
LAN_IF=wlan0
DOCKER_SUBNETS=(172.17.0.0/16 172.20.0.0/16)

GATEWAY=$(nmcli -g IP4.GATEWAY device show "$LAN_IF" 2>/dev/null | head -1)
if [[ -z "$GATEWAY" ]]; then
    echo "docker-vpn-bypass: could not determine gateway for $LAN_IF" >&2
    exit 1
fi

ip route replace default via "$GATEWAY" dev "$LAN_IF" table $TABLE

for subnet in "${DOCKER_SUBNETS[@]}"; do
    ip rule del from "$subnet" table $TABLE priority 100 2>/dev/null || true
    ip rule add from "$subnet" table $TABLE priority 100
done
