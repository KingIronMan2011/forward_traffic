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

ENABLE_IPv6=false
VPS_VPN_IPv6="fd00::1"
HOME_SERVER_IPv6="fd00::2"

# ─── WireGuard config ─────────────────────────────────────────────────────────

wireguard_setup() {
    echo "--- Generating WireGuard keys ---"
    sudo wg genkey | sudo tee /etc/wireguard/privatekey > /dev/null
    sudo chmod 600 /etc/wireguard/privatekey
    sudo wg pubkey < /etc/wireguard/privatekey | sudo tee /etc/wireguard/publickey > /dev/null
    local privkey
    privkey=$(sudo cat /etc/wireguard/privatekey)

    # Build Address and AllowedIPs with optional IPv6
    local addr="10.0.0.2/24"
    local peer_allowed="10.0.0.1/32"
    if $ENABLE_IPv6; then
        addr="10.0.0.2/24, ${HOME_SERVER_IPv6}/64"
        peer_allowed="10.0.0.1/32, ${VPS_VPN_IPv6}/128"
    fi

    echo "--- Creating /etc/wireguard/wg0.conf ---"
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address    = ${addr}
PrivateKey = ${privkey}

[Peer]
# Replace with the output of: cat /etc/wireguard/publickey  (on the VPS)
PublicKey           = <Public_Key_of_VPS>
Endpoint            = ${VPS_PUBLIC_IP}:51820
AllowedIPs          = ${peer_allowed}
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

    read -rp "Enable IPv6 dual-stack WireGuard? [y/N]: " ans_v6
    [[ "${ans_v6,,}" == "y" ]] && ENABLE_IPv6=true || true

    if $ENABLE_IPv6; then
        read -rp "VPS WireGuard IPv6 address [fd00::1]: " v6_vps
        [[ -n "$v6_vps" ]] && VPS_VPN_IPv6="$v6_vps" || true
        read -rp "Home server WireGuard IPv6 address [fd00::2]: " v6_home
        [[ -n "$v6_home" ]] && HOME_SERVER_IPv6="$v6_home" || true
    fi

    install_wireguard
    wireguard_setup
    handle_ufw_for_wireguard
    systemd_enable wg-quick@wg0

    echo
    echo "✓ Home server setup complete."
    echo "  1. Copy your VPS public key into /etc/wireguard/wg0.conf"
    echo "     (replace <Public_Key_of_VPS>)"
    echo "  2. Run: sudo wg-quick up wg0"
    echo
    echo "  Your home server public key (share with VPS):"
    sudo cat /etc/wireguard/publickey

    auto_key_exchange \
        "<Public_Key_of_Home_Server>" \
        "<Public_Key_of_VPS>" \
        /etc/wireguard/publickey
}

main
