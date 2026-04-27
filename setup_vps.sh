#!/bin/bash

set -euo pipefail

# Source shared OS abstraction
LIB="$(dirname "$(realpath "$0")")/lib.sh"
if [[ ! -f "$LIB" ]]; then
    echo "Warning: lib.sh not found next to this script."
    read -rp "Download it from GitHub now? [Y/n]: " _ans
    if [[ "${_ans,,}" != "n" ]]; then
        LIB_URL="https://raw.githubusercontent.com/KingIronMan2011/forward-traffic/main/lib.sh"
        _DEST="$(dirname "$(realpath "$0")")/lib.sh"
        echo "Downloading lib.sh..."
        if command -v curl &>/dev/null; then
            curl -fsSL "$LIB_URL" -o "$_DEST"
        elif command -v wget &>/dev/null; then
            wget -q "$LIB_URL" -O "$_DEST"
        else
            echo "Error: Neither curl nor wget found. Install one and retry." >&2; exit 1
        fi
        echo "Downloaded to $_DEST"
    else
        echo "Error: lib.sh is required to run this script." >&2; exit 1
    fi
fi
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
Address    = 10.0.0.1/24
PrivateKey = ${privkey}
ListenPort = 51820
PostUp     = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PUBLIC_IFACE} -j MASQUERADE
PostDown   = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PUBLIC_IFACE} -j MASQUERADE

[Peer]
# Replace with the output of: cat /etc/wireguard/publickey  (on the home server)
PublicKey  = <Public_Key_of_Home_Server>
AllowedIPs = 10.0.0.2/32
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_sudo_or_root
    detect_os

    echo "VPS setup for WireGuard port forwarding."
    echo

    while true; do
        read -rp "Public network interface (e.g. eth0, ens3): " PUBLIC_IFACE
        ip link show "$PUBLIC_IFACE" &>/dev/null && break || echo "Interface not found. Try again."
    done

    install_wireguard
    wireguard_setup
    enable_ip_forwarding
    systemd_enable wg-quick@wg0

    echo
    echo "✓ VPS setup complete."
    echo "  1. Copy your home server's public key into /etc/wireguard/wg0.conf"
    echo "     (replace <Public_Key_of_Home_Server>)"
    echo "  2. Run: sudo wg-quick up wg0"
    echo
    echo "  Your VPS public key (share with home server):"
    sudo cat /etc/wireguard/publickey
}

main
