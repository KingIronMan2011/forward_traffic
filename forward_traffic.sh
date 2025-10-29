#!/bin/bash

set -euo pipefail

# --- Configuration ---
// ...existing code...
PUBLIC_NETWORK_INTERFACE="ens6"
VPS_VPN_IP="10.0.0.1"
HOME_SERVER_IP="10.0.0.2"

// ...existing code...
check_dependencies() {
    # --- Dependency Check ---
    echo "--- Checking dependencies ---"
    REQUIRED_COMMANDS=("netfilter-persistent" "iptables")
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: '$cmd' is not installed. Installing it now."
            sudo apt update -qq > /dev/null 2>&1
            sudo apt install -y -qq "$cmd" > /dev/null 2>&1
        fi
    done
    echo "All dependencies are installed."
    echo ""
}

# New: ensure sudo or root
require_sudo_or_root() {
    if [ "$EUID" -ne 0 ] && ! command -v sudo &> /dev/null; then
        echo "Error: This script requires root or sudo. Install sudo or run as root."
        exit 1
    fi
}

validate_ip() {
    local ip="$1"
    # Basic IPv4 validation
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "Error: Invalid IP address: $ip"
        exit 1
    fi
    # check octet ranges
    IFS='.' read -r a b c d <<< "$ip"
    for oct in "$a" "$b" "$c" "$d"; do
        if ((oct < 0 || oct > 255)); then
            echo "Error: Invalid IP address: $ip"
            exit 1
        fi
    done
}

interface_exists() {
    if ! ip link show "$PUBLIC_NETWORK_INTERFACE" &> /dev/null; then
        echo "Warning: Network interface '$PUBLIC_NETWORK_INTERFACE' not found."
        read -p "Continue anyway? [y/N]: " ans
        ans="${ans,,}"
        if [[ "$ans" != "y" ]]; then
            echo "Aborting."
            exit 1
        fi
    fi
}

# New helper: add iptables rule only if it doesn't already exist
iptables_add() {
    local table="$1"; shift
    # Try to check the exact rule first; if missing, append it.
    if sudo iptables -t "$table" -C "$@" >/dev/null 2>&1; then
        echo "iptables: rule already exists (skipping): -t $table $*"
    else
        echo "iptables: adding rule: -t $table $*"
        sudo iptables -t "$table" -A "$@"
    fi
}

check_variables() {
    # --- Variable Check ---
    if [[ -z "$PUBLIC_NETWORK_INTERFACE" || -z "$VPS_VPN_IP" || -z "$HOME_SERVER_IP" ]]; then
        echo "Error: One or more required variables are not set."
        echo "Please ensure PUBLIC_NETWORK_INTERFACE, VPS_VPN_IP, and HOME_SERVER_IP are set correctly."
        exit 1
    fi

    validate_ip "$VPS_VPN_IP"
    validate_ip "$HOME_SERVER_IP"
    interface_exists
}

# New: warn if many ports
confirm_large_port_list() {
    local count="$1"
    if [ "$count" -gt 100 ]; then
        echo "Warning: You are about to create $count iptables rules. This may be slow and hard to manage."
        read -p "Proceed? [y/N]: " yn
        yn="${yn,,}"
        if [[ "$yn" != "y" ]]; then
            echo "Aborting."
            exit 1
        fi
    fi
}

parse_ports() {
    # Parse port input and expand ranges and lists
    # Supports: single port (80), ranges (8000-8010), comma-separated (80,443), semicolon-separated (80;443)
    local port_input="$1"
    local ports=()
    
    # Replace semicolons with commas for uniform processing
    port_input="${port_input//;/,}"
    
    # Split by comma
    IFS=',' read -ra port_parts <<< "$port_input"
    
    for part in "${port_parts[@]}"; do
        # Trim whitespace
        part=$(echo "$part" | xargs)
        
        # Check if it's a range (contains hyphen)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start_port="${BASH_REMATCH[1]}"
            end_port="${BASH_REMATCH[2]}"
            
            # Validate range
            if [ "$start_port" -lt 1 ] || [ "$start_port" -gt 65535 ] || [ "$end_port" -lt 1 ] || [ "$end_port" -gt 65535 ]; then
                echo "Error: Port range out of bounds (1-65535): $part"
                exit 1
            fi
            
            if [ "$start_port" -gt "$end_port" ]; then
                echo "Error: Invalid port range (start > end): $part"
                exit 1
            fi
            
            # Expand range
            for ((port=start_port; port<=end_port; port++)); do
                ports+=("$port")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # Single port
            if [ "$part" -lt 1 ] || [ "$part" -gt 65535 ]; then
                echo "Error: Port out of bounds (1-65535): $part"
                exit 1
            fi
            ports+=("$part")
        else
            echo "Error: Invalid port format: $part"
            exit 1
        fi
    done
    
    # Return the array of ports
    echo "${ports[@]}"
}

get_user_input() {
    # --- Input from User ---
    echo "--- Port Forwarding Setup ---"
    echo "This script will configure iptables to forward traffic from your VPS to your home server."
    echo ""
    echo "Port input formats supported:"
    echo "  - Single port: 80"
    echo "  - Port range: 25565-25575"
    echo "  - Comma-separated: 80,443,8080"
    echo "  - Semicolon-separated: 80;443;8080"
    echo "  - Combined: 80,443,8000-8010"
    echo ""
    
    read -p "Enter the port(s) to forward: " PORT_INPUT
    read -p "Enter the PROTOCOL (tcp, udp or all): " PROTOCOL
    
    # Validate inputs
    if [[ -z "$PORT_INPUT" || -z "$PROTOCOL" ]]; then
        echo "Error: Port and protocol cannot be empty."
        exit 1
    fi

    PROTOCOL="${PROTOCOL,,}"
    
    if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" && "$PROTOCOL" != "all" ]]; then
        echo "Error: Invalid protocol. Please enter 'tcp', 'udp', or 'all'."
        exit 1
    fi
    
    # Parse ports
    PORTS=($(parse_ports "$PORT_INPUT"))
    
    if [ ${#PORTS[@]} -eq 0 ]; then
        echo "Error: No valid ports found."
        exit 1
    fi

    # Warn for large lists
    confirm_large_port_list "${#PORTS[@]}"
    
    echo ""
    echo "Ports to forward: ${PORTS[@]}"
    echo "Protocol: $PROTOCOL"
    echo ""
}

apply_rules() {
    echo ""
    echo "--- Applying iptables rules ---"
    
    # 1. Enable IP forwarding (if not already enabled)
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    # Persist ip_forward
    echo "Persisting net.ipv4.ip_forward=1 to /etc/sysctl.d/99-forward.conf"
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forward.conf > /dev/null
    sudo sysctl --system > /dev/null 2>&1
    
    # Loop through all ports
    for PORT in "${PORTS[@]}"; do
        echo "Configuring rules for port $PORT..."
        
        # 2. PREROUTING: Redirect incoming traffic from VPS public IP to home server's internal IP and port
        iptables_add nat -p "$PROTOCOL" --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
        
        # 3. POSTROUTING: Rewrite source IP for outgoing traffic from home server to appear as VPS
        iptables_add nat -p "$PROTOCOL" -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
        
        # 4. FORWARD: Allow forwarded traffic through the firewall
        iptables_add filter -p "$PROTOCOL" -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    done
    
    # 5. MASQUERADE for general outgoing traffic from the VPN interface
    echo "Adding MASQUERADE rule for VPN interface..."
    iptables_add nat -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
    
    # 6. Saving iptables
    echo "Saving iptables..."
    sudo netfilter-persistent save
    
    echo ""
    echo "--- Rules applied successfully for ${#PORTS[@]} port(s)! ---"
    echo ""
}

apply_rules_all() {
    echo ""
    echo "--- Applying iptables rules ---"
    
    # 1. Enable IP forwarding (if not already enabled)
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    # Persist ip_forward
    echo "Persisting net.ipv4.ip_forward=1 to /etc/sysctl.d/99-forward.conf"
    echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forward.conf > /dev/null
    sudo sysctl --system > /dev/null 2>&1
    
    # Loop through all ports
    for PORT in "${PORTS[@]}"; do
        echo "Configuring rules for port $PORT (TCP and UDP)..."
        
        # 2. PREROUTING: Redirect incoming traffic from VPS public IP to home server's internal IP and port
        iptables_add nat -p tcp --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
        iptables_add nat -p udp --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
        
        # 3. POSTROUTING: Rewrite source IP for outgoing traffic from home server to appear as VPS
        iptables_add nat -p tcp -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
        iptables_add nat -p udp -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
        
        # 4. FORWARD: Allow forwarded traffic through the firewall
        iptables_add filter -p tcp -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
        iptables_add filter -p udp -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    done
    
    # 5. MASQUERADE for general outgoing traffic from the VPN interface
    echo "Adding MASQUERADE rule for VPN interface..."
    iptables_add nat -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
    
    # 6. Saving iptables
    echo "Saving iptables..."
    sudo netfilter-persistent save
    
    echo ""
    echo "--- Rules applied successfully for ${#PORTS[@]} port(s)! ---"
    echo ""
}

main() {
    require_sudo_or_root
    check_dependencies
    check_variables
    get_user_input
    
    if [[ "$PROTOCOL" = "tcp" ]]; then
        apply_rules
        elif [[ "$PROTOCOL" = "udp" ]]; then
        apply_rules
        elif [[ "$PROTOCOL" = "all" ]]; then
        apply_rules_all
    fi
}

main
