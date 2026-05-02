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

# ─── Defaults ─────────────────────────────────────────────────────────────────

CONFIG_FILE="/etc/forward-traffic.conf"
ROUTES_FILE="/etc/forward-traffic.routes"
DRY_RUN=false
ENABLE_IPv6=false

PUBLIC_NETWORK_INTERFACE=""
VPS_VPN_IP=""
HOME_SERVER_IP=""
VPS_VPN_IPv6="fd00::1"
HOME_SERVER_IPv6="fd00::2"
HOME_SERVERS=()

# ─── Dependencies ─────────────────────────────────────────────────────────────

check_dependencies() {
    echo "--- Checking dependencies ---"
    detect_os
    check_firewalld_conflict
    command -v iptables &>/dev/null || pkg_install iptables
    install_iptables_persistence
    $ENABLE_IPv6 && install_ip6tables_persistence || true
    echo "All dependencies satisfied."; echo
}

# ─── First-run wizard ─────────────────────────────────────────────────────────

run_wizard() {
    echo
    echo "  ┌─ Forward Traffic — First Run Wizard ───────────────────────────"
    echo "  │  Configure the VPN IPs and network interface used for forwarding."
    echo "  │  Answers are saved to $CONFIG_FILE for future runs."
    echo "  └────────────────────────────────────────────────────────────────"
    echo

    # Public interface
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
        prompt_required PUBLIC_NETWORK_INTERFACE "  Public network interface"
    done

    # Try to read VPN IPs from existing wg0.conf first
    detect_wg_config_values

    prompt_with_default VPS_VPN_IP  "  VPS WireGuard VPN IP"         "${VPS_VPN_IP:-10.0.0.1}"
    prompt_with_default HOME_SERVER_IP "  Home server WireGuard VPN IP" "${HOME_SERVER_IP:-10.0.0.2}"
    validate_ip "$VPS_VPN_IP"
    validate_ip "$HOME_SERVER_IP"

    # IPv6
    read -rp "  Enable IPv6 forwarding? [y/N]: " _v6
    if [[ "${_v6,,}" == "y" ]]; then
        ENABLE_IPv6=true
        prompt_with_default VPS_VPN_IPv6    "  VPS WireGuard IPv6"         "$VPS_VPN_IPv6"
        prompt_with_default HOME_SERVER_IPv6 "  Home server WireGuard IPv6" "$HOME_SERVER_IPv6"
    fi

    echo
    _save_config
}

# ─── Config persistence ───────────────────────────────────────────────────────

_save_config() {
    local servers_serialized
    servers_serialized=$(printf '"%s" ' "${HOME_SERVERS[@]+"${HOME_SERVERS[@]}"}")
    local tmpfile
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<EOF
# forward-traffic config — auto-generated $(date '+%Y-%m-%d %H:%M:%S')
PUBLIC_NETWORK_INTERFACE="$PUBLIC_NETWORK_INTERFACE"
VPS_VPN_IP="$VPS_VPN_IP"
HOME_SERVER_IP="$HOME_SERVER_IP"
VPS_VPN_IPv6="$VPS_VPN_IPv6"
HOME_SERVER_IPv6="$HOME_SERVER_IPv6"
ENABLE_IPv6=$ENABLE_IPv6
HOME_SERVERS=($servers_serialized)
EOF
    sudo cp "$tmpfile" "$CONFIG_FILE"
    rm -f "$tmpfile"
    sudo chmod 644 "$CONFIG_FILE"
    echo "Config saved to $CONFIG_FILE"
}

_load_config() {
    load_script_config "$CONFIG_FILE" || return 1
    echo "Loaded config from $CONFIG_FILE"
    printf "  %-26s %s\n" "Interface:"          "$PUBLIC_NETWORK_INTERFACE"
    printf "  %-26s %s\n" "VPS VPN IP:"         "$VPS_VPN_IP"
    printf "  %-26s %s\n" "Home server VPN IP:" "$HOME_SERVER_IP"
    $ENABLE_IPv6 && {
        printf "  %-26s %s\n" "VPS IPv6:"         "$VPS_VPN_IPv6"
        printf "  %-26s %s\n" "Home server IPv6:" "$HOME_SERVER_IPv6"
    } || true
    [[ ${#HOME_SERVERS[@]} -gt 0 ]] && \
        printf "  %-26s %s\n" "Extra home servers:" "${HOME_SERVERS[*]}" || true
    echo
    return 0
}

# ─── Variable validation ──────────────────────────────────────────────────────

check_variables() {
    [[ -n "$VPS_VPN_IP" && -n "$HOME_SERVER_IP" ]] || {
        echo "Error: VPS_VPN_IP and HOME_SERVER_IP must be set." >&2; exit 1
    }
    validate_ip "$VPS_VPN_IP"
    validate_ip "$HOME_SERVER_IP"
    [[ -z "$PUBLIC_NETWORK_INTERFACE" ]] && detect_public_interface
    if [[ -z "$PUBLIC_NETWORK_INTERFACE" ]] || ! ip link show "$PUBLIC_NETWORK_INTERFACE" &>/dev/null 2>&1; then
        echo "Warning: Interface '${PUBLIC_NETWORK_INTERFACE:-<none>}' not found."
        prompt_required PUBLIC_NETWORK_INTERFACE "  Enter interface name manually (e.g. eth0, ens3)"
        ip link show "$PUBLIC_NETWORK_INTERFACE" &>/dev/null || {
            echo "Error: Interface '$PUBLIC_NETWORK_INTERFACE' still not found." >&2; exit 1
        }
    fi
    echo "Using interface: $PUBLIC_NETWORK_INTERFACE"
}

# ─── Multi-home-server selection ──────────────────────────────────────────────

select_forward_target() {
    local -a labels=() ips=()
    labels+=("Default (${HOME_SERVER_IP})")
    ips+=("$HOME_SERVER_IP")
    for entry in "${HOME_SERVERS[@]+"${HOME_SERVERS[@]}"}"; do
        labels+=("${entry%%:*} (${entry##*:})")
        ips+=("${entry##*:}")
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

# ─── Port input ───────────────────────────────────────────────────────────────

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

# ─── iptables wrappers ────────────────────────────────────────────────────────

iptables_rule() {
    local action="$1" table="$2"; shift 2
    if $DRY_RUN; then
        local verb; [[ "$action" == "add" ]] && verb="-A" || verb="-D"
        echo "[dry-run] iptables -t $table $verb $*"; return
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

manage_rules() {
    local action="$1"; shift
    local protos=("$@")
    local target="${FORWARD_TARGET:-$HOME_SERVER_IP}"
    local target_v6="${FORWARD_TARGET_IPv6:-$HOME_SERVER_IPv6}"

    [[ "$action" == "add" ]] && {
        echo "--- Applying rules → $target ---"
        enable_ip_forwarding
        $ENABLE_IPv6 && enable_ipv6_forwarding || true
    } || echo "--- Removing rules (target: $target) ---"

    for PORT in "${PORTS[@]}"; do
        for proto in "${protos[@]}"; do
            echo "  port $PORT / $proto..."
            iptables_rule "$action" nat    PREROUTING  -p "$proto" --dport "$PORT" -j DNAT --to-destination "$target:$PORT"
            iptables_rule "$action" nat    POSTROUTING -p "$proto" -d "$target"   --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
            iptables_rule "$action" filter FORWARD     -p "$proto" -d "$target"   --dport "$PORT" -m state --state NEW,ESTABLISHED -j ACCEPT
            if $ENABLE_IPv6; then
                ip6tables_rule "$action" nat    PREROUTING  -p "$proto" --dport "$PORT" -j DNAT --to-destination "[$target_v6]:$PORT"
                ip6tables_rule "$action" nat    POSTROUTING -p "$proto" -d "$target_v6" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IPv6"
                ip6tables_rule "$action" filter FORWARD     -p "$proto" -d "$target_v6" --dport "$PORT" -m state --state NEW,ESTABLISHED -j ACCEPT
            fi
            ufw_manage_port "$action" "$PORT" "$proto"
            firewalld_manage_port "$action" "$PORT" "$proto" "$target" "$VPS_VPN_IP"
        done
    done

    if [[ "$action" == "add" ]]; then
        iptables_rule add nat POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
        $ENABLE_IPv6 && ip6tables_rule add nat POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE || true
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

# ─── List rules ───────────────────────────────────────────────────────────────

list_rules() {
    echo; echo "--- Active forwarding rules (PREROUTING DNAT) ---"; echo
    _print_dnat_table "iptables"  "$(sudo iptables  -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)"
    if $ENABLE_IPv6 && command -v ip6tables &>/dev/null; then
        echo
        _print_dnat_table "ip6tables" "$(sudo ip6tables -t nat -L PREROUTING -n 2>/dev/null | grep DNAT || true)"
    fi
    echo
}

_print_dnat_table() {
    local label="$1" rules="$2"
    echo "  [$label]"
    [[ -z "$rules" ]] && { echo "  No rules found."; return; }
    printf "  %-8s  %-8s  %s\n" "PROTO" "PORT" "DESTINATION"
    printf "  %-8s  %-8s  %s\n" "--------" "--------" "-----------"
    while IFS= read -r line; do
        proto=$(awk '{print $1}' <<< "$line")
        dport=$(grep -oP 'dpt:\K[0-9]+' <<< "$line" || echo "?")
        dst=$(grep -oP 'to:\K\S+'       <<< "$line" || echo "?")
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
  --reconfigure   Re-run the setup wizard even if a config exists
  --audit [all]   Show audit log (last 50 entries, or all)
  --help          Show this help message

Port formats:  80  |  25565-25575  |  80,443,8080  |  80,443,8000-8010

Config file:  $CONFIG_FILE   (edit this to change settings)
Audit log:    $AUDIT_LOG

EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local mode="add" reconfigure=false

    for arg in "$@"; do
        case "$arg" in
            --remove)       mode="remove"     ;;
            --list)         mode="list"       ;;
            --dry-run)      DRY_RUN=true      ;;
            --ipv6)         ENABLE_IPv6=true  ;;
            --reconfigure)  reconfigure=true  ;;
            --audit)        ;;  # handled below
            --help)         usage; exit 0     ;;
            all)            ;;  # audit subarg
            *) echo "Error: Unknown option '$arg'. Use --help." >&2; exit 1 ;;
        esac
    done

    # --audit is special: show log and exit immediately (no sudo needed for reading)
    [[ "${1:-}" == "--audit" ]] && { view_audit_log "${2:-50}"; exit 0; }

    require_sudo_or_root
    check_dependencies

    [[ "$mode" == "list" ]] && { list_rules; exit 0; }

    # Config: first run → wizard. Subsequent runs → load + confirm (or --reconfigure)
    if $reconfigure || ! _load_config; then
        [[ -f "$CONFIG_FILE" ]] && echo "Re-running setup wizard..." || echo "No config found — running first-time setup wizard."
        run_wizard
    else
        if ! confirm_or_rewizard "Loaded config ($CONFIG_FILE)" \
            PUBLIC_NETWORK_INTERFACE VPS_VPN_IP HOME_SERVER_IP ENABLE_IPv6; then
            run_wizard
        fi
    fi

    check_variables
    get_user_input

    local protos=("$PROTOCOL")
    [[ "$PROTOCOL" == "all" ]] && protos=(tcp udp)

    manage_rules "$mode" "${protos[@]}"
    [[ "$mode" == "add" ]] && ! $DRY_RUN && _save_config || true
}

main "$@"
