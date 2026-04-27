#!/bin/bash

set -euo pipefail

# Source shared OS abstraction
LIB="$(dirname "$(realpath "$0")")/lib.sh"
[[ -f "$LIB" ]] || { echo "Error: lib.sh not found next to this script." >&2; exit 1; }
# shellcheck source=lib.sh
source "$LIB"

# ─── WireGuard config ─────────────────────────────────────────────────────────

wireguard_setup() {
    echo "--- Generating WireGuard keys ---"
    sudo wg genkey | sudo tee /etc/wireguard/privatekey > /dev/null
    sudo chmod 600 /etc/wireguard/privatekey
    sudo wg pubkey < /etc/wireguard/privatekey | sudo tee /etc/wireguard/publickey > /dev/null
    local privkey
    privkey=$(sudo cat /etc/wireguard/privatekey)

    echo "--- Creating /etc/wireguard/wg0.conf ---"
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address    = 10.0.0.2/24
PrivateKey = ${privkey}

[Peer]
# Replace with the output of: cat /etc/wireguard/publickey  (on the VPS)
PublicKey           = <Public_Key_of_VPS>
Endpoint            = ${VPS_PUBLIC_IP}:51820
AllowedIPs          = 10.0.0.1/32
PersistentKeepalive = 25
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_sudo_or_root
    detect_os

    echo "Home server setup for WireGuard port forwarding."
    echo

    while true; do
        read -rp "Public IP address of the VPS: " VPS_PUBLIC_IP
        [[ "$VPS_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break || echo "Invalid IP format. Try again."
    done

    install_wireguard
    wireguard_setup
    systemd_enable wg-quick@wg0

    echo
    echo "✓ Home server setup complete."
    echo "  1. Copy your VPS public key into /etc/wireguard/wg0.conf"
    echo "     (replace <Public_Key_of_VPS>)"
    echo "  2. Run: sudo wg-quick up wg0"
    echo
    echo "  Your home server public key (share with VPS):"
    sudo cat /etc/wireguard/publickey
}

main
