#!/usr/bin/env bash
# Keeps Docker's bridge networks routing straight out over the LAN,
# bypassing whatever default route the local Surfshark client installs.
# Without this, gluetun's own VPN tunnel gets nested inside the local
# VPN tunnel (double-VPN), which is what breaks Prowlarr/qbittorrent
# when the local VPN is connected.
set -euo pipefail

TABLE=100
# Must be higher than Tailscale's own "from all lookup 52" rule (priority
# 5270) so Tailscale gets first crack at routing traffic to its peers.
# Otherwise replies from containers back to Tailscale devices (e.g. your
# phone) get pulled into this bypass and shoved at the LAN gateway instead
# of out tailscale0, since table 52 (Tailscale's peer routes) lives outside
# of table 100 entirely.
RULE_PRIORITY=20000
LAN_IF=wlan0
DOCKER_SUBNETS=(172.17.0.0/16 172.20.0.0/16)

GATEWAY=$(nmcli -g IP4.GATEWAY device show "$LAN_IF" 2>/dev/null | head -1)
if [[ -z "$GATEWAY" ]]; then
    echo "docker-vpn-bypass: could not determine gateway for $LAN_IF" >&2
    exit 1
fi

# The docker bridges' own gateway addresses (e.g. 172.20.0.1) fall inside
# the subnets we're redirecting, so table 100 needs their connected routes
# too -- otherwise host<->container traffic on those bridges (including
# replies to published-port/hairpin connections) gets shoved toward the
# LAN gateway instead of delivered on-link, and just dies.
for subnet in "${DOCKER_SUBNETS[@]}"; do
    bridge_dev=$(ip route show table main "$subnet" | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')
    if [[ -n "$bridge_dev" ]]; then
        ip route replace "$subnet" dev "$bridge_dev" table $TABLE
    fi
done

ip route replace default via "$GATEWAY" dev "$LAN_IF" table $TABLE

# The LAN subnet itself also needs its connected route in table 100.
# Replies from a container (e.g. nginx proxying /jellyfin) back to a LAN
# client route through this table since they're sourced from the bridge
# subnet -- without the LAN's own on-link route, table 100 only has the
# default route, so those replies get sent as a routed hop via the
# gateway instead of delivered directly on the LAN segment, and most
# routers/switches won't loop that back in. This broke direct LAN
# connections (e.g. smart TV apps) to Jellyfin.
LAN_SUBNET=$(ip route show table main dev "$LAN_IF" scope link | awk '{print $1}' | head -1)
if [[ -n "$LAN_SUBNET" ]]; then
    ip route replace "$LAN_SUBNET" dev "$LAN_IF" table $TABLE
fi

for subnet in "${DOCKER_SUBNETS[@]}"; do
    ip rule del from "$subnet" table $TABLE 2>/dev/null || true
    ip rule add from "$subnet" table $TABLE priority $RULE_PRIORITY
done
