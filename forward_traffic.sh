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

# ─── Defaults (overridden by config file) ─────────────────────────────────────

PUBLIC_NETWORK_INTERFACE="ens6"
VPS_VPN_IP="10.0.0.1"
HOME_SERVER_IP="10.0.0.2"
# IPv6 WireGuard VPN addresses (fd00::/64 is a private ULA prefix)
VPS_VPN_IPv6="fd00::1"
HOME_SERVER_IPv6="fd00::2"
# Additional home servers: associative entries "label:ip"
HOME_SERVERS=()

CONFIG_FILE="/etc/forward-traffic.conf"
ROUTES_FILE="/etc/forward-traffic.routes"
DRY_RUN=false
ENABLE_IPv6=false

# ─── Dependency check ─────────────────────────────────────────────────────────

check_dependencies() {
    echo "--- Checking dependencies ---"
    detect_os
    check_firewalld_conflict
    if ! command -v iptables &>/dev/null; then
        echo "'iptables' not found — installing..."
        pkg_install iptables
    fi
    install_iptables_persistence
    if $ENABLE_IPv6; then
        install_ip6tables_persistence
    fi
    echo "All dependencies satisfied."; echo
}

# ─── Config persistence ───────────────────────────────────────────────────────

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    echo "Loaded config from $CONFIG_FILE"
    printf "  Interface  : %s\n  VPS IP     : %s\n  Home IP    : %s\n" \
        "$PUBLIC_NETWORK_INTERFACE" "$VPS_VPN_IP" "$HOME_SERVER_IP"
    if $ENABLE_IPv6; then
        printf "  VPS IPv6   : %s\n  Home IPv6  : %s\n" "$VPS_VPN_IPv6" "$HOME_SERVER_IPv6"
    fi
    if [[ ${#HOME_SERVERS[@]} -gt 0 ]]; then
        printf "  Extra hosts: %s\n" "${HOME_SERVERS[*]}"
    fi
    echo
}

save_config() {
    echo "Saving config to $CONFIG_FILE..."
    local servers_serialized
    servers_serialized=$(printf '"%s" ' "${HOME_SERVERS[@]+"${HOME_SERVERS[@]}"}")
    sudo tee "$CONFIG_FILE" > /dev/null <<EOF
PUBLIC_NETWORK_INTERFACE="$PUBLIC_NETWORK_INTERFACE"
VPS_VPN_IP="$VPS_VPN_IP"
HOME_SERVER_IP="$HOME_SERVER_IP"
VPS_VPN_IPv6="$VPS_VPN_IPv6"
HOME_SERVER_IPv6="$HOME_SERVER_IPv6"
ENABLE_IPv6=$ENABLE_IPv6
HOME_SERVERS=($servers_serialized)
EOF
    echo "Config saved."
}

# ─── Multi-home-server selection ──────────────────────────────────────────────

# Sets FORWARD_TARGET and FORWARD_TARGET_IPv6 based on user selection or default
select_forward_target() {
    # Build full list: default home server + any extras from HOME_SERVERS
    local -a labels=() ips=()
    labels+=("Default (${HOME_SERVER_IP})")
    ips+=("$HOME_SERVER_IP")

    for entry in "${HOME_SERVERS[@]+"${HOME_SERVERS[@]}"}"; do
        local label ip
        label="${entry%%:*}"
        ip="${entry##*:}"
        labels+=("$label ($ip)")
        ips+=("$ip")
    done

    if [[ ${#ips[@]} -eq 1 ]]; then
        FORWARD_TARGET="${ips[0]}"
        FORWARD_TARGET_IPv6="$HOME_SERVER_IPv6"
        return
    fi

    echo "--- Select target home server ---"
    for i in "${!labels[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${labels[$i]}"
    done
    echo "  A) Add a new home server"
    echo

    while true; do
        read -rp "Select [1-${#ips[@]} / A]: " sel
        if [[ "${sel,,}" == "a" ]]; then
            read -rp "  Label (e.g. Gaming PC): " new_label
            read -rp "  IP address: " new_ip
            validate_ip "$new_ip"
            HOME_SERVERS+=("${new_label}:${new_ip}")
            FORWARD_TARGET="$new_ip"
            FORWARD_TARGET_IPv6="$HOME_SERVER_IPv6"
            echo "  Added: $new_label → $new_ip"
            break
        elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#ips[@]} )); then
            FORWARD_TARGET="${ips[$((sel-1))]}"
            FORWARD_TARGET_IPv6="$HOME_SERVER_IPv6"
            echo "  Target: ${labels[$((sel-1))]}"
            break
        else
            echo "  Invalid selection."
        fi
    done
    echo
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

    select_forward_target
}

# ─── iptables + ip6tables wrappers ────────────────────────────────────────────

# iptables_rule <add|remove> <table> <chain> [rule args...]
iptables_rule() {
    local action="$1" table="$2"; shift 2
    if $DRY_RUN; then
        local verb; [[ "$action" == "add" ]] && verb="-A" || verb="-D"
        echo "[dry-run] iptables -t $table $verb $*"
        return
    fi
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
    local target="${FORWARD_TARGET:-$HOME_SERVER_IP}"
    local target_v6="${FORWARD_TARGET_IPv6:-$HOME_SERVER_IPv6}"

    if [[ "$action" == "add" ]]; then
        echo "--- Applying rules → $target ---"
        enable_ip_forwarding
        $ENABLE_IPv6 && enable_ipv6_forwarding || true
    else
        echo "--- Removing rules (target: $target) ---"
    fi

    for PORT in "${PORTS[@]}"; do
        for proto in "${protos[@]}"; do
            echo "  port $PORT / $proto..."

            # IPv4 iptables rules
            iptables_rule "$action" nat    PREROUTING  -p "$proto" --dport "$PORT" -j DNAT --to-destination "$target:$PORT"
            iptables_rule "$action" nat    POSTROUTING -p "$proto" -d "$target"   --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
            iptables_rule "$action" filter FORWARD     -p "$proto" -d "$target"   --dport "$PORT" -m state --state NEW,ESTABLISHED -j ACCEPT

            # IPv6 ip6tables rules (only if enabled)
            if $ENABLE_IPv6; then
                ip6tables_rule "$action" nat    PREROUTING  -p "$proto" --dport "$PORT" -j DNAT --to-destination "[$target_v6]:$PORT"
                ip6tables_rule "$action" nat    POSTROUTING -p "$proto" -d "$target_v6" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IPv6"
                ip6tables_rule "$action" filter FORWARD     -p "$proto" -d "$target_v6" --dport "$PORT" -m state --state NEW,ESTABLISHED -j ACCEPT
            fi

            # UFW (if active)
            ufw_manage_port "$action" "$PORT" "$proto"

            # Firewalld (if active)
            firewalld_manage_port "$action" "$PORT" "$proto" "$target" "$VPS_VPN_IP"
        done
    done

    if [[ "$action" == "add" ]]; then
        iptables_rule add nat POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
        if $ENABLE_IPv6; then
            ip6tables_rule add nat POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
        fi
    fi

    if $DRY_RUN; then
        printf "\n--- [dry-run] %d port(s) would be %sed (no changes made). ---\n\n" "${#PORTS[@]}" "$action"
    else
        save_iptables
        $ENABLE_IPv6 && save_ip6tables || true
        firewalld_save
        audit_log "$action" "$PROTOCOL" "${PORTS[*]}" "$target"
        printf "\n--- Done: %d port(s) %sed → %s ---\n\n" "${#PORTS[@]}" "$action" "$target"
    fi
}

# ─── List active rules ────────────────────────────────────────────────────────

list_rules() {
    echo
    echo "--- Active forwarding rules (PREROUTING DNAT) ---"
    echo
    _print_dnat_table "iptables" "$(sudo iptables  -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)"
    if $ENABLE_IPv6 && command -v ip6tables &>/dev/null; then
        echo
        _print_dnat_table "ip6tables" "$(sudo ip6tables -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)"
    fi
    echo
}

_print_dnat_table() {
    local label="$1" rules="$2"
    echo "  [$label]"
    if [[ -z "$rules" ]]; then
        echo "  No rules found."
        return
    fi
    printf "  %-8s  %-8s  %s\n" "PROTO" "PORT" "DESTINATION"
    printf "  %-8s  %-8s  %s\n" "--------" "--------" "-----------"
    while IFS= read -r line; do
        proto=$(awk '{print $1}' <<< "$line")
        dport=$(grep -oP 'dpt:\K[0-9]+' <<< "$line" || echo "?")
        dst=$(grep -oP 'to:\K\S+' <<< "$line" || echo "?")
        printf "  %-8s  %-8s  %s\n" "$proto" "$dport" "$dst"
    done <<< "$rules"
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF

Usage: $0 [options]

  (no flag)       Forward port(s) from VPS to a home server
  --remove        Remove previously added forwarding rules
  --list          Show all currently active DNAT forwarding rules
  --dry-run       Show what would be applied without making changes
  --ipv6          Also apply ip6tables rules for IPv6 traffic
  --audit [all]   Show audit log (last 50 entries, or all)
  --help          Show this help message

Port formats:  80  |  25565-25575  |  80,443,8080  |  80,443,8000-8010

Multi-home-server: if multiple home servers are configured in $CONFIG_FILE,
you will be prompted to select a target when adding or removing rules.

Config auto-saved to: $CONFIG_FILE
Audit log at:         $AUDIT_LOG
Routes file:          $ROUTES_FILE

EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="add"
    case "${1:-}" in
        --remove)   mode="remove"               ;;
        --list)     mode="list"                 ;;
        --dry-run)  DRY_RUN=true                ;;
        --ipv6)     ENABLE_IPv6=true            ;;
        --audit)    view_audit_log "${2:-50}"; exit 0 ;;
        --help)     usage; exit 0               ;;
        "")         ;;
        *) echo "Error: Unknown option '$1'. Use --help." >&2; exit 1 ;;
    esac

    # Allow combining flags: --dry-run and --ipv6 can follow any positional
    for arg in "$@"; do
        [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
        [[ "$arg" == "--ipv6"   ]] && ENABLE_IPv6=true
    done

    require_sudo_or_root
    check_dependencies

    if [[ "$mode" == "list" ]]; then list_rules; exit 0; fi

    load_config
    check_variables
    get_user_input

    local protos=("$PROTOCOL")
    [[ "$PROTOCOL" == "all" ]] && protos=(tcp udp)

    manage_rules "$mode" "${protos[@]}"
    [[ "$mode" == "add" ]] && ! $DRY_RUN && save_config || true
}

main "$@"
