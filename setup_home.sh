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

CONFIG_FILE="/etc/forward-traffic-home.conf"

# Config variables with defaults
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
    echo "  ┌─ Home Server Setup Wizard ─────────────────────────────────────"
    echo "  │  This will configure WireGuard on your home server."
    echo "  │  Answers are saved to $CONFIG_FILE for future runs."
    echo "  └────────────────────────────────────────────────────────────────"
    echo

    # VPS public IP — required, no auto-detect possible from home side
    echo "  Enter the public IP of your VPS."
    echo "  (It was printed at the end of setup_vps.sh)"
    while true; do
        prompt_required VPS_PUBLIC_IP "  VPS public IP"
        validate_ip "$VPS_PUBLIC_IP" && break || echo "  Invalid IP format. Try again."
    done

    # WireGuard port
    prompt_with_default WG_PORT "  WireGuard port on VPS" "$WG_PORT"

    # VPN subnet — auto-detect conflicts, then let user confirm
    detect_vpn_subnet
    prompt_with_default WG_VPN_IP_VPS  "  VPS VPN IP (must match setup_vps.sh)"  "$WG_VPN_IP_VPS"
    prompt_with_default WG_VPN_IP_HOME "  Home server VPN IP (must match setup_vps.sh)" "$WG_VPN_IP_HOME"

    # IPv6
    read -rp "  Enable IPv6 dual-stack? [y/N]: " _v6
    if [[ "${_v6,,}" == "y" ]]; then
        ENABLE_IPv6=true
        prompt_with_default VPS_VPN_IPv6    "  VPS WireGuard IPv6 (must match setup_vps.sh)" "$VPS_VPN_IPv6"
        prompt_with_default HOME_SERVER_IPv6 "  Home server WireGuard IPv6"                   "$HOME_SERVER_IPv6"
    fi

    echo
    save_script_config "$CONFIG_FILE" \
        VPS_PUBLIC_IP WG_PORT \
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

    local addr="${WG_VPN_IP_HOME}/24"
    local peer_allowed="${WG_VPN_IP_VPS}/32"
    if $ENABLE_IPv6; then
        addr="${WG_VPN_IP_HOME}/24, ${HOME_SERVER_IPv6}/64"
        peer_allowed="${WG_VPN_IP_VPS}/32, ${VPS_VPN_IPv6}/128"
    fi

    echo "--- Creating /etc/wireguard/wg0.conf ---"
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOF
[Interface]
Address    = ${addr}
PrivateKey = ${privkey}

[Peer]
# Replace with the output of: cat /etc/wireguard/publickey  (on the VPS)
PublicKey           = <Public_Key_of_VPS>
Endpoint            = ${VPS_PUBLIC_IP}:${WG_PORT}
AllowedIPs          = ${peer_allowed}
PersistentKeepalive = 25
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
    echo "=== Home Server Setup for WireGuard Port Forwarding ==="

    # First run: wizard. Subsequent runs: silent load.
    # To change settings: edit $CONFIG_FILE or pass --edit-config.
    local edit_config=false
    [[ "${1:-}" == "--edit-config" ]] && edit_config=true

    if $edit_config; then
        _edit_config
    elif load_script_config "$CONFIG_FILE"; then
        echo "Config loaded from $CONFIG_FILE"
        show_config_summary "Current config" \
            VPS_PUBLIC_IP WG_PORT \
            WG_VPN_IP_VPS WG_VPN_IP_HOME \
            ENABLE_IPv6 VPS_VPN_IPv6 HOME_SERVER_IPv6
    else
        echo "No config found — running first-time setup wizard."
        run_wizard
    fi

    backup_existing_wg_config
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
    echo
    echo "  To change settings: edit $CONFIG_FILE directly,"
    echo "  or re-run with: sudo $0 --edit-config"

    auto_key_exchange \
        "<Public_Key_of_Home_Server>" \
        "<Public_Key_of_VPS>" \
        /etc/wireguard/publickey
}

main
