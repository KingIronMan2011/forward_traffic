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
