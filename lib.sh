#!/bin/bash
# lib.sh — shared OS abstraction for forward-traffic scripts
# Sourced by forward_traffic.sh, setup_vps.sh, setup_home.sh

# ─── OS / Package manager detection ──────────────────────────────────────────

detect_os() {
    OS_FAMILY=""
    PKG_MANAGER=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID,,}" in
            ubuntu|debian|linuxmint|pop|kali|raspbian|elementary) OS_FAMILY="debian" ;;
            centos|rhel|almalinux|rocky|ol)                       OS_FAMILY="rhel"   ;;
            fedora)                                                OS_FAMILY="fedora" ;;
            arch|manjaro|endeavouros|garuda)                      OS_FAMILY="arch"   ;;
            opensuse*|sles)                                        OS_FAMILY="suse"   ;;
            alpine)                                                OS_FAMILY="alpine" ;;
            *)
                case "${ID_LIKE,,}" in
                    *debian*)          OS_FAMILY="debian" ;;
                    *rhel*|*fedora*)   OS_FAMILY="rhel"   ;;
                    *arch*)            OS_FAMILY="arch"   ;;
                    *suse*)            OS_FAMILY="suse"   ;;
                    *)                 OS_FAMILY="unknown" ;;
                esac
                ;;
        esac
    fi

    if   command -v apt-get &>/dev/null; then PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then PKG_MANAGER="pacman"
    elif command -v zypper  &>/dev/null; then PKG_MANAGER="zypper"
    elif command -v apk     &>/dev/null; then PKG_MANAGER="apk"
    else
        echo "Error: No supported package manager found (apt/dnf/yum/pacman/zypper/apk)." >&2
        exit 1
    fi

    echo "Detected OS family: ${OS_FAMILY:-unknown}, package manager: $PKG_MANAGER"
}

# ─── Package management ───────────────────────────────────────────────────────

pkg_update() {
    case "$PKG_MANAGER" in
        apt)    sudo apt-get update -qq &>/dev/null ;;
        dnf)    sudo dnf makecache -q --refresh &>/dev/null ;;
        yum)    sudo yum makecache -q &>/dev/null ;;
        pacman) sudo pacman -Sy --noconfirm &>/dev/null ;;
        zypper) sudo zypper refresh -q &>/dev/null ;;
        apk)    sudo apk update -q &>/dev/null ;;
    esac
}

pkg_install() {
    local updated=false
    if [[ "${_PKG_UPDATED:-}" != "1" ]]; then
        pkg_update; _PKG_UPDATED=1; updated=true
    fi
    case "$PKG_MANAGER" in
        apt)    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" &>/dev/null ;;
        dnf)    sudo dnf install -y -q "$@" &>/dev/null ;;
        yum)    sudo yum install -y -q "$@" &>/dev/null ;;
        pacman) sudo pacman -S --noconfirm --needed "$@" &>/dev/null ;;
        zypper) sudo zypper install -y -q "$@" &>/dev/null ;;
        apk)    sudo apk add -q "$@" &>/dev/null ;;
    esac
}

# ─── WireGuard install ────────────────────────────────────────────────────────

install_wireguard() {
    echo "--- Installing WireGuard ---"
    sudo mkdir -p /etc/wireguard

    case "$OS_FAMILY" in
        debian)
            pkg_install wireguard
            ;;
        rhel)
            # EPEL provides wireguard-tools on RHEL/CentOS
            if [[ "$PKG_MANAGER" == "dnf" ]]; then
                sudo dnf install -y -q epel-release &>/dev/null || true
                # Enable CRB/PowerTools repo (required on RHEL 9 / CentOS Stream 9)
                sudo dnf config-manager --set-enabled crb &>/dev/null \
                    || sudo dnf config-manager --set-enabled powertools &>/dev/null \
                    || true
            else
                # CentOS 7 — EPEL via RPM
                sudo yum install -y -q https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm &>/dev/null || true
            fi
            pkg_install wireguard-tools
            ;;
        fedora)
            pkg_install wireguard-tools
            ;;
        arch)
            pkg_install wireguard-tools
            ;;
        suse)
            pkg_install wireguard-tools
            ;;
        alpine)
            pkg_install wireguard-tools
            ;;
        *)
            echo "Warning: Unknown OS family — attempting wireguard-tools..."
            pkg_install wireguard-tools || pkg_install wireguard
            ;;
    esac

    echo "WireGuard installed."
}

# ─── iptables persistence ─────────────────────────────────────────────────────

install_iptables_persistence() {
    echo "--- Setting up iptables persistence ---"
    case "$OS_FAMILY" in
        debian)
            pkg_install iptables-persistent
            sudo mkdir -p /etc/iptables
            ;;
        rhel|fedora)
            pkg_install iptables-services
            sudo systemctl enable iptables &>/dev/null || true
            ;;
        arch)
            # iptables is already installed; just enable the service
            sudo mkdir -p /etc/iptables
            sudo systemctl enable iptables.service &>/dev/null || true
            ;;
        *)
            echo "No native persistence package known for this distro — using systemd fallback..."
            _install_iptables_restore_service
            ;;
    esac
}

_install_iptables_restore_service() {
    sudo mkdir -p /etc/iptables
    sudo tee /etc/systemd/system/iptables-restore.service > /dev/null << 'EOF'
[Unit]
Description=Restore iptables forwarding rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable iptables-restore.service &>/dev/null
}

save_iptables() {
    echo "Saving iptables rules..."
    case "$OS_FAMILY" in
        debian|arch|suse|alpine|unknown)
            sudo mkdir -p /etc/iptables
            sudo iptables-save | sudo tee /etc/iptables/rules.v4 > /dev/null
            echo "  → saved to /etc/iptables/rules.v4"
            ;;
        rhel|fedora)
            sudo iptables-save | sudo tee /etc/sysconfig/iptables > /dev/null
            echo "  → saved to /etc/sysconfig/iptables"
            ;;
    esac
}

# ─── IP forwarding ────────────────────────────────────────────────────────────

enable_ip_forwarding() {
    sudo sysctl -w net.ipv4.ip_forward=1 &>/dev/null
    # /etc/sysctl.d/ is the modern preferred location on all systemd distros
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forward-traffic.conf > /dev/null
    sudo sysctl --system &>/dev/null || sudo sysctl -p &>/dev/null || true
    echo "IP forwarding enabled."
}

# ─── systemd helper ───────────────────────────────────────────────────────────

systemd_enable() {
    local unit="$1"
    if command -v systemctl &>/dev/null; then
        sudo systemctl enable "$unit" &>/dev/null && echo "Enabled: $unit" || echo "Warning: could not enable $unit"
    else
        echo "Warning: systemd not found — enable '$unit' manually on boot."
    fi
}

# ─── Sanity checks ────────────────────────────────────────────────────────────

require_sudo_or_root() {
    [[ "$EUID" -eq 0 ]] || command -v sudo &>/dev/null || {
        echo "Error: root or sudo required." >&2; exit 1
    }
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Error: Invalid IP: $ip" >&2; exit 1; }
    IFS='.' read -r a b c d <<< "$ip"
    for oct in "$a" "$b" "$c" "$d"; do
        ((oct >= 0 && oct <= 255)) || { echo "Error: Invalid IP octet in: $ip" >&2; exit 1; }
    done
}

# ─── UFW support ──────────────────────────────────────────────────────────────

# Returns 0 if UFW is installed and active
ufw_active() {
    command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"
}

# Call once during setup to prepare UFW for WireGuard + forwarding
handle_ufw_for_wireguard() {
    ufw_active || return 0
    echo "UFW is active — configuring for WireGuard..."
    sudo ufw allow 51820/udp &>/dev/null
    # Allow forwarded traffic through UFW
    sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    sudo ufw reload &>/dev/null
    echo "UFW: port 51820/udp allowed, forward policy set to ACCEPT."
}

# Add or remove a single port/proto in UFW if it is active
# ufw_manage_port <add|remove> <port> <proto>
ufw_manage_port() {
    ufw_active || return 0
    local action="$1" port="$2" proto="$3"
    if [[ "$action" == "add" ]]; then
        sudo ufw allow "$port/$proto" &>/dev/null \
            && echo "UFW: allowed $port/$proto" \
            || echo "UFW: warning — could not allow $port/$proto"
    else
        sudo ufw delete allow "$port/$proto" &>/dev/null \
            && echo "UFW: removed $port/$proto" \
            || echo "UFW: warning — could not remove $port/$proto"
    fi
}

# ─── SSH key exchange ─────────────────────────────────────────────────────────

# Offer to SSH to the peer machine and swap WireGuard public keys automatically.
# Usage: auto_key_exchange <local_placeholder> <remote_placeholder> <local_pubkey_file>
#   local_placeholder  — string in the REMOTE machine's wg0.conf to replace (e.g. "<Public_Key_of_VPS>")
#   remote_placeholder — string in the LOCAL machine's wg0.conf to replace (e.g. "<Public_Key_of_Home_Server>")
#   local_pubkey_file  — path to this machine's public key file
auto_key_exchange() {
    local local_ph="$1" remote_ph="$2" local_pubkey_file="$3"
    local local_pubkey
    local_pubkey=$(sudo cat "$local_pubkey_file")

    echo
    echo "--- Automatic Key Exchange (optional) ---"
    echo "  You can SSH into the peer machine now to insert keys on both sides automatically."
    read -rp "  SSH to peer machine to exchange keys? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || { echo "  Skipped — insert keys manually."; return 0; }

    read -rp "  Peer SSH target (user@host): " SSH_TARGET
    read -rp "  SSH port [22]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"

    echo "  Connecting to $SSH_TARGET..."

    # 1. Insert our public key into peer's wg0.conf
    # 2. Read back peer's public key
    local remote_pubkey
    remote_pubkey=$(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
        "$SSH_TARGET" \
        "sudo sed -i 's|${local_ph}|${local_pubkey}|' /etc/wireguard/wg0.conf \
         && sudo cat /etc/wireguard/publickey" 2>/dev/null) || {
        echo "  Warning: SSH command failed. Exchange keys manually." >&2
        return 1
    }

    if [[ -z "$remote_pubkey" ]]; then
        echo "  Warning: Could not read remote public key. Check /etc/wireguard/publickey on peer." >&2
        return 1
    fi

    # Insert remote's public key into our local wg0.conf
    sudo sed -i "s|${remote_ph}|${remote_pubkey}|" /etc/wireguard/wg0.conf

    echo "  ✓ Keys exchanged successfully."
    echo "    Peer public key: $remote_pubkey"
    echo "    Inserted into local /etc/wireguard/wg0.conf"
    echo "    Remote /etc/wireguard/wg0.conf updated with our public key."
}

# ─── Audit logging ────────────────────────────────────────────────────────────

AUDIT_LOG="/var/log/forward-traffic.log"

# audit_log <action> <proto> <ports_str> <target_ip>
audit_log() {
    local action="$1" proto="$2" ports="$3" target="$4"
    local ts user
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    user=$(logname 2>/dev/null || echo "${SUDO_USER:-${USER:-unknown}}")
    local entry="$ts | ${action^^} | $proto | $ports | $target | user:$user"
    echo "$entry" | sudo tee -a "$AUDIT_LOG" > /dev/null
}

view_audit_log() {
    local n="${1:-50}"
    echo
    echo "--- Audit Log ($AUDIT_LOG) ---"
    echo
    if [[ ! -f "$AUDIT_LOG" ]]; then
        echo "  No audit log found."
    else
        printf "  %-19s  %-7s  %-5s  %-20s  %-15s  %s\n" \
            "TIMESTAMP" "ACTION" "PROTO" "PORTS" "TARGET" "USER"
        printf "  %-19s  %-7s  %-5s  %-20s  %-15s  %s\n" \
            "-------------------" "-------" "-----" "--------------------" "---------------" "----"
        if [[ "$n" == "all" ]]; then
            cat "$AUDIT_LOG"
        else
            tail -n "$n" "$AUDIT_LOG"
        fi | while IFS='|' read -r ts action proto ports target user; do
            printf "  %-19s  %-7s  %-5s  %-20s  %-15s  %s\n" \
                "${ts// /}" "${action// /}" "${proto// /}" "${ports// /}" "${target// /}" "${user// /}"
        done
    fi
    echo
}

# ─── Firewalld support ────────────────────────────────────────────────────────

firewalld_active() {
    command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state &>/dev/null
}

# firewalld_manage_port <add|remove> <port> <proto> <home_ip> <vps_ip>
firewalld_manage_port() {
    firewalld_active || return 0
    local action="$1" port="$2" proto="$3" home_ip="$4"
    local rule="port=${port}:proto=${proto}:toport=${port}:toaddr=${home_ip}"

    if [[ "$action" == "add" ]]; then
        sudo firewall-cmd --add-forward-port="$rule" &>/dev/null \
            && echo "firewalld: forward-port added: $port/$proto → $home_ip" \
            || echo "firewalld: warning — could not add forward-port $port/$proto"
        sudo firewall-cmd --add-masquerade &>/dev/null || true
    else
        sudo firewall-cmd --remove-forward-port="$rule" &>/dev/null \
            && echo "firewalld: forward-port removed: $port/$proto → $home_ip" \
            || echo "firewalld: warning — could not remove forward-port $port/$proto"
    fi
}

firewalld_save() {
    firewalld_active || return 0
    sudo firewall-cmd --runtime-to-permanent &>/dev/null \
        && echo "firewalld: rules saved (runtime → permanent)" \
        || echo "firewalld: warning — could not make rules permanent"
}

# Update install_iptables_persistence to warn when firewalld is active
# (iptables rules still needed for DNAT; firewalld handles them differently)
check_firewalld_conflict() {
    if firewalld_active; then
        echo "Warning: firewalld is active. iptables rules will be applied directly"
        echo "         and firewalld rich rules will also be added for persistence."
        echo "         If you experience conflicts, consider stopping firewalld:"
        echo "           sudo systemctl stop firewalld && sudo systemctl disable firewalld"
        echo
    fi
}

# ─── IPv6 / ip6tables ─────────────────────────────────────────────────────────

# ip6tables_rule <add|remove> <table> <chain> [rule args...]
# DRY_RUN is respected if set
ip6tables_rule() {
    local action="$1" table="$2"; shift 2
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local verb; [[ "$action" == "add" ]] && verb="-A" || verb="-D"
        echo "[dry-run] ip6tables -t $table $verb $*"
        return
    fi
    if ! command -v ip6tables &>/dev/null; then
        echo "ip6tables: not found — skipping IPv6 rule" >&2; return
    fi
    if sudo ip6tables -t "$table" -C "$@" &>/dev/null; then
        [[ "$action" == "add" ]] \
            && echo "ip6tables: already exists (skip): -t $table $*" \
            || { echo "ip6tables: removing: -t $table $*"; sudo ip6tables -t "$table" -D "$@"; }
    else
        [[ "$action" == "add" ]] \
            && { echo "ip6tables: adding: -t $table $*"; sudo ip6tables -t "$table" -A "$@"; } \
            || echo "ip6tables: not found (skip): -t $table $*"
    fi
}

save_ip6tables() {
    command -v ip6tables-save &>/dev/null || return
    echo "Saving ip6tables rules..."
    case "${OS_FAMILY:-debian}" in
        debian|arch|suse|alpine|unknown)
            sudo mkdir -p /etc/iptables
            sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 > /dev/null
            echo "  → saved to /etc/iptables/rules.v6"
            ;;
        rhel|fedora)
            sudo ip6tables-save | sudo tee /etc/sysconfig/ip6tables > /dev/null
            echo "  → saved to /etc/sysconfig/ip6tables"
            ;;
    esac
}

install_ip6tables_persistence() {
    command -v ip6tables &>/dev/null || return
    case "${OS_FAMILY:-debian}" in
        debian)
            # iptables-persistent also handles ip6tables on Debian/Ubuntu
            ;;
        rhel|fedora)
            # ip6tables-services is a separate package
            pkg_install ip6tables-services &>/dev/null || true
            ;;
    esac
}

enable_ipv6_forwarding() {
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    echo "net.ipv6.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.d/99-forward-traffic.conf > /dev/null
    sudo sysctl --system &>/dev/null || sudo sysctl -p &>/dev/null || true
    echo "IPv6 forwarding enabled."
}
