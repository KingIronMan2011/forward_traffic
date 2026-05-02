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

CONFIG_FILE="/etc/forward-traffic-vps.conf"

# Config variables with defaults
PUBLIC_NETWORK_INTERFACE=""
VPS_PUBLIC_IP=""
WG_PORT=51820
WG_VPN_IP_VPS="10.0.0.1"
WG_VPN_IP_HOME="10.0.0.2"
ENABLE_IPv6=false
VPS_VPN_IPv6="fd00::1"
HOME_SERVER_IPv6="fd00::2"

# ─── First-run wizard ─────────────────────────────────────────────────────────

run_wizard() {
    echo
    echo "  ┌─ VPS Setup Wizard ─────────────────────────────────────────────"
    echo "  │  This will configure WireGuard on your VPS."
    echo "  │  Answers are saved to $CONFIG_FILE for future runs."
    echo "  └────────────────────────────────────────────────────────────────"
    echo

    # Interface
    detect_public_interface
    if [[ -n "$PUBLIC_NETWORK_INTERFACE" ]]; then
        prompt_with_default PUBLIC_NETWORK_INTERFACE \
            "  Public network interface (auto-detected)" \
            "$PUBLIC_NETWORK_INTERFACE"
    else
        prompt_required PUBLIC_NETWORK_INTERFACE \
            "  Public network interface (e.g. eth0, ens3)"
    fi
    while ! ip link show "$PUBLIC_NETWORK_INTERFACE" &>/dev/null; do
        echo "  Interface '$PUBLIC_NETWORK_INTERFACE' not found. Try again."
        prompt_required PUBLIC_NETWORK_INTERFACE \
            "  Public network interface (e.g. eth0, ens3)"
    done

    # WireGuard port
    detect_wireguard_port
    prompt_with_default WG_PORT "  WireGuard listen port" "$WG_PORT"

    # VPN subnet
    detect_vpn_subnet
    prompt_with_default WG_VPN_IP_VPS "  VPS VPN IP" "$WG_VPN_IP_VPS"
    prompt_with_default WG_VPN_IP_HOME "  Home server VPN IP" "$WG_VPN_IP_HOME"

    # IPv6
    read -rp "  Enable IPv6 dual-stack? [y/N]: " _v6
    if [[ "${_v6,,}" == "y" ]]; then
        ENABLE_IPv6=true
        prompt_with_default VPS_VPN_IPv6   "  VPS WireGuard IPv6 address"         "$VPS_VPN_IPv6"
        prompt_with_default HOME_SERVER_IPv6 "  Home server WireGuard IPv6 address" "$HOME_SERVER_IPv6"
    fi

    echo
    save_script_config "$CONFIG_FILE" \
        PUBLIC_NETWORK_INTERFACE WG_PORT \
        WG_VPN_IP_VPS WG_VPN_IP_HOME \
        ENABLE_IPv6 VPS_VPN_IPv6 HOME_SERVER_IPv6
}

# ─── WireGuard config ─────────────────────────────────────────────────────────

wireguard_setup() {
    echo "--- Generating WireGuard keys ---"
    sudo wg genkey | sudo tee /etc/wireguard/privatekey > /dev/null
    sudo chmod 600 /etc/wireguard/privatekey
    sudo wg pubkey < /etc/wireguard/privatekey | sudo tee /etc/wireguard/publickey > /dev/null
    local privkey
    privkey=$(sudo cat /etc/wireguard/privatekey)

    local addr="${WG_VPN_IP_VPS}/24"
    local peer_allowed="${WG_VPN_IP_HOME}/32"
    local postup_v6="" postdown_v6=""
    if $ENABLE_IPv6; then
        addr="${WG_VPN_IP_VPS}/24, ${VPS_VPN_IPv6}/64"
        peer_allowed="${WG_VPN_IP_HOME}/32, ${HOME_SERVER_IPv6}/128"
        postup_v6="; sysctl -w net.ipv6.conf.all.forwarding=1; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE"
        postdown_v6="; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE"
    fi

    echo "--- Creating /etc/wireguard/wg0.conf ---"
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address    = ${addr}
PrivateKey = ${privkey}
ListenPort = ${WG_PORT}
PostUp     = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE${postup_v6}
PostDown   = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE${postdown_v6}

[Peer]
# Replace with the output of: cat /etc/wireguard/publickey  (on the home server)
PublicKey  = <Public_Key_of_Home_Server>
AllowedIPs = ${peer_allowed}
EOF
}

# ─── Config editor ───────────────────────────────────────────────────────────

_edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "No config file found at $CONFIG_FILE — running wizard first."
        run_wizard; return
    fi
    local editor="${EDITOR:-}"
    [[ -z "$editor" ]] && for e in nano vim vi; do
        command -v "$e" &>/dev/null && editor="$e" && break
    done
    if [[ -n "$editor" ]]; then
        echo "Opening $CONFIG_FILE in $editor..."
        sudo "$editor" "$CONFIG_FILE"
        load_script_config "$CONFIG_FILE"
    else
        echo "No editor found. Edit $CONFIG_FILE manually and re-run."; exit 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_sudo_or_root
    detect_os

    echo
    echo "=== VPS Setup for WireGuard Port Forwarding ==="

    # First run: wizard. Subsequent runs: silent load.
    # To change settings: edit $CONFIG_FILE or pass --edit-config.
    local edit_config=false
    [[ "${1:-}" == "--edit-config" ]] && edit_config=true

    if $edit_config; then
        _edit_config
    elif load_script_config "$CONFIG_FILE"; then
        echo "Config loaded from $CONFIG_FILE"
        show_config_summary "Current config" \
            PUBLIC_NETWORK_INTERFACE WG_PORT \
            WG_VPN_IP_VPS WG_VPN_IP_HOME \
            ENABLE_IPv6 VPS_VPN_IPv6 HOME_SERVER_IPv6
    else
        echo "No config found — running first-time setup wizard."
        run_wizard
    fi

    backup_existing_wg_config
    install_wireguard
    wireguard_setup
    enable_ip_forwarding
    $ENABLE_IPv6 && enable_ipv6_forwarding || true
    handle_ufw_for_wireguard
    systemd_enable wg-quick@wg0

    # Detect and display public IP for the user
    detect_vps_public_ip

    echo
    echo "✓ VPS setup complete."
    echo "  1. Copy your home server's public key into /etc/wireguard/wg0.conf"
    echo "     (replace <Public_Key_of_Home_Server>)"
    echo "  2. Run: sudo wg-quick up wg0"
    echo
    echo "  Your VPS public key (share with home server):"
    sudo cat /etc/wireguard/publickey
    echo
    [[ -n "${VPS_PUBLIC_IP:-}" ]] && \
        echo "  Your VPS public IP (enter this in setup_home.sh): $VPS_PUBLIC_IP"
    echo
    echo "  To change settings: edit $CONFIG_FILE directly,"
    echo "  or re-run with: sudo $0 --edit-config"

    auto_key_exchange \
        "<Public_Key_of_VPS>" \
        "<Public_Key_of_Home_Server>" \
        /etc/wireguard/publickey
}

main
