#!/bin/bash

set -euo pipefail

# Source shared OS abstraction
LIB="$(dirname "$(realpath "$0")")/lib.sh"
[[ -f "$LIB" ]] || { echo "Error: lib.sh not found next to this script." >&2; exit 1; }
# shellcheck source=lib.sh
source "$LIB"

# --- Configuration (overridden by config file if present) ---
PUBLIC_NETWORK_INTERFACE="ens6"
VPS_VPN_IP="10.0.0.1"
HOME_SERVER_IP="10.0.0.2"
CONFIG_FILE="/etc/forward-traffic.conf"

# ─── Dependency check ─────────────────────────────────────────────────────────

check_dependencies() {
    echo "--- Checking dependencies ---"
    detect_os
    if ! command -v iptables &>/dev/null; then
        echo "'iptables' not found — installing..."
        pkg_install iptables
    fi
    install_iptables_persistence
    echo "All dependencies satisfied."; echo
}

# ─── Config persistence ───────────────────────────────────────────────────────

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    echo "Loaded config from $CONFIG_FILE"
    printf "  Interface : %s\n  VPS VPN IP: %s\n  Home IP   : %s\n\n" \
        "$PUBLIC_NETWORK_INTERFACE" "$VPS_VPN_IP" "$HOME_SERVER_IP"
}

save_config() {
    echo "Saving config to $CONFIG_FILE..."
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
PUBLIC_NETWORK_INTERFACE="$PUBLIC_NETWORK_INTERFACE"
VPS_VPN_IP="$VPS_VPN_IP"
HOME_SERVER_IP="$HOME_SERVER_IP"
EOF
    echo "Config saved."
}

# ─── Variable / interface check ───────────────────────────────────────────────

check_variables() {
    [[ -n "$PUBLIC_NETWORK_INTERFACE" && -n "$VPS_VPN_IP" && -n "$HOME_SERVER_IP" ]] || {
        echo "Error: PUBLIC_NETWORK_INTERFACE, VPS_VPN_IP and HOME_SERVER_IP must all be set." >&2; exit 1
    }
    validate_ip "$VPS_VPN_IP"
    validate_ip "$HOME_SERVER_IP"
    if ! ip link show "$PUBLIC_NETWORK_INTERFACE" &>/dev/null; then
        echo "Warning: Interface '$PUBLIC_NETWORK_INTERFACE' not found."
        read -rp "Continue anyway? [y/N]: " ans
        [[ "${ans,,}" == "y" ]] || { echo "Aborting."; exit 1; }
    fi
}

# ─── Port parsing ─────────────────────────────────────────────────────────────

parse_ports() {
    local input="${1//;/,}" ports=()
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
            ((s >= 1 && s <= 65535 && e >= 1 && e <= 65535)) || { echo "Error: Port range out of bounds: $part" >&2; exit 1; }
            ((s <= e)) || { echo "Error: Range start > end: $part" >&2; exit 1; }
            for ((p = s; p <= e; p++)); do ports+=("$p"); done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            ((part >= 1 && part <= 65535)) || { echo "Error: Port out of bounds: $part" >&2; exit 1; }
            ports+=("$part")
        else
            echo "Error: Invalid port format: $part" >&2; exit 1
        fi
    done
    echo "${ports[@]}"
}

get_user_input() {
    echo "--- Port Forwarding Setup ---"
    echo "Formats: single (80)  range (8000-8010)  comma/semicolon-separated (80,443;8080)  combined"
    echo
    read -rp "Port(s): " PORT_INPUT
    read -rp "Protocol (tcp / udp / all): " PROTOCOL
    [[ -n "$PORT_INPUT" && -n "$PROTOCOL" ]] || { echo "Error: Port and protocol cannot be empty." >&2; exit 1; }
    PROTOCOL="${PROTOCOL,,}"
    [[ "$PROTOCOL" =~ ^(tcp|udp|all)$ ]] || { echo "Error: Protocol must be tcp, udp, or all." >&2; exit 1; }

    # shellcheck disable=SC2207
    PORTS=($(parse_ports "$PORT_INPUT"))
    [[ ${#PORTS[@]} -gt 0 ]] || { echo "Error: No valid ports found." >&2; exit 1; }

    if [[ ${#PORTS[@]} -gt 100 ]]; then
        echo "Warning: ${#PORTS[@]} rules will be created — this may be slow."
        read -rp "Proceed? [y/N]: " yn
        [[ "${yn,,}" == "y" ]] || { echo "Aborting."; exit 1; }
    fi

    printf "\nPorts : %s\nProto : %s\n\n" "${PORTS[*]}" "$PROTOCOL"
}

# ─── iptables wrapper ─────────────────────────────────────────────────────────

# iptables_rule <add|remove> <table> <chain> [rule args...]
iptables_rule() {
    local action="$1" table="$2"; shift 2
    if sudo iptables -t "$table" -C "$@" &>/dev/null; then
        [[ "$action" == "add" ]] \
            && echo "iptables: already exists (skip): -t $table $*" \
            || { echo "iptables: removing: -t $table $*"; sudo iptables -t "$table" -D "$@"; }
    else
        [[ "$action" == "add" ]] \
            && { echo "iptables: adding: -t $table $*"; sudo iptables -t "$table" -A "$@"; } \
            || echo "iptables: not found (skip): -t $table $*"
    fi
}

# ─── Rule management ──────────────────────────────────────────────────────────

# manage_rules <add|remove> <proto> [proto ...]
manage_rules() {
    local action="$1"; shift
    local protos=("$@")

    if [[ "$action" == "add" ]]; then
        echo "--- Applying iptables rules ---"
        enable_ip_forwarding
    else
        echo "--- Removing iptables rules ---"
    fi

    for PORT in "${PORTS[@]}"; do
        for proto in "${protos[@]}"; do
            echo "  port $PORT / $proto..."
            iptables_rule "$action" nat    PREROUTING  -p "$proto" --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
            iptables_rule "$action" nat    POSTROUTING -p "$proto" -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
            iptables_rule "$action" filter FORWARD     -p "$proto" -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED -j ACCEPT
        done
    done

    if [[ "$action" == "add" ]]; then
        iptables_rule add nat POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
    fi

    save_iptables
    printf "\n--- Done: %d port(s) %sed. ---\n\n" "${#PORTS[@]}" "$action"
}

# ─── List active rules ────────────────────────────────────────────────────────

list_rules() {
    echo
    echo "--- Active forwarding rules (PREROUTING DNAT) ---"
    echo
    local rules
    rules=$(sudo iptables -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)
    if [[ -z "$rules" ]]; then
        echo "  No forwarding rules found."
    else
        printf "  %-8s  %-8s  %s\n" "PROTO" "PORT" "DESTINATION"
        printf "  %-8s  %-8s  %s\n" "--------" "--------" "-----------"
        while IFS= read -r line; do
            proto=$(awk '{print $1}' <<< "$line")
            dport=$(grep -oP 'dpt:\K[0-9]+' <<< "$line" || echo "?")
            dst=$(grep -oP 'to:\K\S+'       <<< "$line" || echo "?")
            printf "  %-8s  %-8s  %s\n" "$proto" "$dport" "$dst"
        done <<< "$rules"
    fi
    echo
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

Usage: $0 [--remove | --list | --help]

  (no flag)   Forward port(s) from the VPS to the home server
  --remove    Remove previously added forwarding rules
  --list      Show all currently active DNAT forwarding rules
  --help      Show this help message

Port formats:  80  |  25565-25575  |  80,443,8080  |  80,443,8000-8010

Config is auto-saved to $CONFIG_FILE after first run.

EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="add"
    case "${1:-}" in
        --remove) mode="remove" ;;
        --list)   mode="list"   ;;
        --help)   usage; exit 0 ;;
        "")       ;;
        *) echo "Error: Unknown option '$1'. Use --help." >&2; exit 1 ;;
    esac

    require_sudo_or_root
    check_dependencies

    if [[ "$mode" == "list" ]]; then list_rules; exit 0; fi

    load_config
    check_variables
    get_user_input

    local protos=("$PROTOCOL")
    [[ "$PROTOCOL" == "all" ]] && protos=(tcp udp)

    manage_rules "$mode" "${protos[@]}"
    [[ "$mode" == "add" ]] && save_config || true
}

main "$@"
