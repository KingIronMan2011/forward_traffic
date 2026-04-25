#!/bin/bash

set -euo pipefail

# ─── Helpers ─────────────────────────────────────────────────────────────────

install_wireguard() {
    echo "--- Installing WireGuard ---"
    sudo apt-get update -qq &>/dev/null
    sudo apt-get install -y -qq wireguard &>/dev/null
    sudo mkdir -p /etc/wireguard
    echo "WireGuard installed."
}

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

persist_ip_forwarding() {
    sudo sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null \
        || echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null || {
        echo "Error: root or sudo required." >&2; exit 1
    }

    echo "VPS setup for WireGuard port forwarding."
    echo
    while true; do
        read -rp "Public network interface (e.g. eth0, ens3): " PUBLIC_IFACE
        ip link show "$PUBLIC_IFACE" &>/dev/null && break || echo "Interface not found. Try again."
    done

    install_wireguard
    wireguard_setup
    persist_ip_forwarding
    sudo systemctl enable wg-quick@wg0

    echo
    echo "✓ VPS setup complete."
    echo "  1. Copy your home server's public key into /etc/wireguard/wg0.conf"
    echo "     (replace <Public_Key_of_Home_Server>)"
    echo "  2. Run: sudo wg-quick up wg0"
    echo "  Your VPS public key (share with home server): $(sudo cat /etc/wireguard/publickey)"
}

main
