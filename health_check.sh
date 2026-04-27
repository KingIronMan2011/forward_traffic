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

CONFIG_FILE="/etc/forward-traffic.conf"

# ─── Checks ───────────────────────────────────────────────────────────────────

OK="  \e[32m✓\e[0m"
FAIL="  \e[31m✗\e[0m"
WARN="  \e[33m!\e[0m"

check_ip_forwarding() {
    echo "--- IP Forwarding ---"
    local val
    val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "$val" == "1" ]]; then
        echo -e "$OK IP forwarding is enabled"
    else
        echo -e "$FAIL IP forwarding is DISABLED — run forward_traffic.sh to fix"
    fi
}

check_wireguard() {
    echo "--- WireGuard ---"
    if ! command -v wg &>/dev/null; then
        echo -e "$FAIL wg command not found — is WireGuard installed?"
        return
    fi
    if sudo wg show wg0 &>/dev/null; then
        echo -e "$OK wg0 interface is UP"
        local peer_count handshake
        peer_count=$(sudo wg show wg0 peers 2>/dev/null | wc -l)
        echo -e "$OK Peers configured: $peer_count"
        # Check latest handshake — if > 3 min ago the tunnel may be stale
        handshake=$(sudo wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
        if [[ -n "$handshake" && "$handshake" != "0" ]]; then
            local age=$(( $(date +%s) - handshake ))
            if (( age < 180 )); then
                echo -e "$OK Last handshake: ${age}s ago (tunnel is active)"
            else
                echo -e "$WARN Last handshake: ${age}s ago (tunnel may be stale)"
            fi
        else
            echo -e "$WARN No handshake recorded yet — peer may not have connected"
        fi
    else
        echo -e "$FAIL wg0 interface is DOWN — run: sudo wg-quick up wg0"
    fi
}

check_vpn_reachability() {
    echo "--- VPN Connectivity ---"
    local target="${HOME_SERVER_IP:-10.0.0.2}"
    if ping -c2 -W2 "$target" &>/dev/null; then
        echo -e "$OK Home server VPN IP ($target) is reachable"
    else
        echo -e "$FAIL Home server VPN IP ($target) is NOT reachable"
    fi
}

check_iptables_rules() {
    echo "--- iptables DNAT Rules ---"
    local rules
    rules=$(sudo iptables -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)
    if [[ -z "$rules" ]]; then
        echo -e "$WARN No DNAT forwarding rules found — run forward_traffic.sh to add some"
    else
        local count
        count=$(echo "$rules" | wc -l)
        echo -e "$OK $count DNAT rule(s) active:"
        printf "    %-8s  %-8s  %s\n" "PROTO" "PORT" "DESTINATION"
        printf "    %-8s  %-8s  %s\n" "--------" "--------" "-----------"
        while IFS= read -r line; do
            proto=$(awk '{print $1}' <<< "$line")
            dport=$(grep -oP 'dpt:\K[0-9]+' <<< "$line" || echo "?")
            dst=$(grep -oP 'to:\K\S+' <<< "$line" || echo "?")
            printf "    %-8s  %-8s  %s\n" "$proto" "$dport" "$dst"
        done <<< "$rules"
    fi
}

check_port_reachability() {
    local rules
    rules=$(sudo iptables -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)
    [[ -z "$rules" ]] && return

    echo "--- Port Reachability ---"
    if ! command -v nc &>/dev/null && ! command -v nmap &>/dev/null; then
        echo -e "$WARN Cannot check ports — install nc (netcat) or nmap"
        return
    fi

    while IFS= read -r line; do
        local proto dport dst_host
        proto=$(awk '{print $1}' <<< "$line")
        dport=$(grep -oP 'dpt:\K[0-9]+' <<< "$line" || echo "")
        dst_host=$(grep -oP 'to:\K[^:]+' <<< "$line" || echo "")
        [[ -z "$dport" || -z "$dst_host" ]] && continue

        if command -v nc &>/dev/null && [[ "$proto" == "tcp" ]]; then
            if nc -z -w3 "$dst_host" "$dport" &>/dev/null; then
                echo -e "$OK $dst_host:$dport/tcp is reachable"
            else
                echo -e "$FAIL $dst_host:$dport/tcp is NOT reachable"
            fi
        elif command -v nmap &>/dev/null; then
            if nmap -p "$dport" -sU "$dst_host" 2>/dev/null | grep -q "open"; then
                echo -e "$OK $dst_host:$dport/$proto appears open"
            else
                echo -e "$FAIL $dst_host:$dport/$proto appears closed or filtered"
            fi
        fi
    done <<< "$rules"
}

check_ufw() {
    command -v ufw &>/dev/null || return
    echo "--- UFW ---"
    local status
    status=$(sudo ufw status 2>/dev/null | head -1)
    echo -e "$OK UFW status: $status"
    local fwd_policy
    fwd_policy=$(grep '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [[ "$fwd_policy" == "ACCEPT" ]]; then
        echo -e "$OK Forward policy: ACCEPT"
    else
        echo -e "$WARN Forward policy: ${fwd_policy:-unknown} (should be ACCEPT for forwarding)"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_sudo_or_root

    echo -e "\n\e[1m=== Forward-Traffic Health Check ===\e[0m\n"

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        printf "Config loaded from %s\n" "$CONFIG_FILE"
        printf "  Interface : %s\n  VPS VPN IP: %s\n  Home IP   : %s\n\n" \
            "${PUBLIC_NETWORK_INTERFACE:-?}" "${VPS_VPN_IP:-?}" "${HOME_SERVER_IP:-?}"
    else
        echo -e "$WARN No config found at $CONFIG_FILE — using defaults\n"
        PUBLIC_NETWORK_INTERFACE="ens6"
        VPS_VPN_IP="10.0.0.1"
        HOME_SERVER_IP="10.0.0.2"
    fi

    check_ip_forwarding;       echo
    check_wireguard;           echo
    check_vpn_reachability;    echo
    check_iptables_rules;      echo
    check_port_reachability;   echo
    check_ufw;                 echo

    echo -e "\e[1m=== Done ===\e[0m\n"
}

main "$@"
