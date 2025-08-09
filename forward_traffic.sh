#!/bin/bash

# --- Configuration ---
# IMPORTANT: Replace 'eth0' with your actual public network interface name (e.g., ens3, venet0).
# You can find this using 'ip a' or 'ifconfig'.
PUBLIC_NETWORK_INTERFACE="ens6"

# IMPORTANT: Replace '10.0.0.1' with the internal VPN IP address of your VPS.
# This is the 'Address' you set in your VPS's wg0.conf file.
VPS_VPN_IP="10.0.0.1"

HOME_SERVER_IP="10.0.0.2"

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

check_variables() {
    # --- Variable Check ---
    if [[ -z "$PUBLIC_NETWORK_INTERFACE" || -z "$VPS_VPN_IP" || -z "$HOME_SERVER_IP" ]]; then
        echo "Error: One or more required variables are not set."
        echo "Please ensure PUBLIC_NETWORK_INTERFACE, VPS_VPN_IP, and HOME_SERVER_IP are set correctly."
        exit 1
    fi
}

get_user_input() {
    # --- Input from User ---
    echo "--- Port Forwarding Setup ---"
    echo "This script will configure iptables to forward traffic from your VPS to your home server."
    echo ""
    
    read -p "Enter the port to forward (e.g., 80 for HTTP, 443 for HTTPS): " PORT
    read -p "Enter the PROTOCOL (tcp, udp or all): " PROTOCOL
    
    # Validate inputs
    if [[ -z "$PORT" || -z "$PROTOCOL" ]]; then
        echo "Error: Port and protocol cannot be empty."
        exit 1
    fi
    
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "Error: Invalid port number. Please enter a number between 1 and 65535."
        exit 1
    fi
    
    if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" && "$PROTOCOL" != "all" ]]; then
        echo "Error: Invalid protocol. Please enter 'tcp', 'udp', or 'all'."
        exit 1
    fi
}

apply_rules() {
    echo ""
    echo "--- Applying iptables rules ---"
    
    # 1. Enable IP forwarding (if not already enabled)
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    # 2. PREROUTING: Redirect incoming traffic from VPS public IP to home server's internal IP and port
    echo "Adding PREROUTING rule..."
    sudo iptables -t nat -A PREROUTING -p "$PROTOCOL" --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
    
    # 3. POSTROUTING: Rewrite source IP for outgoing traffic from home server to appear as VPS
    echo "Adding POSTROUTING rule..."
    sudo iptables -t nat -A POSTROUTING -p "$PROTOCOL" -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
    
    # 4. FORWARD: Allow forwarded traffic through the firewall
    echo "Adding FORWARD rule..."
    sudo iptables -A FORWARD -p "$PROTOCOL" -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    
    # 5. MASQUERADE for general outgoing traffic from the VPN interface
    # This ensures that traffic originating from the VPN tunnel (e.g., your home server accessing the internet through the VPS)
    # is properly NATed to the VPS's public IP.
    echo "Adding MASQUERADE rule for VPN interface..."
    sudo iptables -t nat -A POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
    
    # 6. Saving iptables
    echo "Saving iptables..."
    sudo netfilter-persistent save
    
    echo ""
    echo "--- Rules applied successfully! ---"
    echo ""
}

apply_rules_all() {
    echo ""
    echo "--- Applying iptables rules ---"
    
    # 1. Enable IP forwarding (if not already enabled)
    echo "Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    # 2. PREROUTING: Redirect incoming traffic from VPS public IP to home server's internal IP and port
    echo "Adding PREROUTING rule..."
    sudo iptables -t nat -A PREROUTING -p tcp --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
    sudo iptables -t nat -A PREROUTING -p udp --dport "$PORT" -j DNAT --to-destination "$HOME_SERVER_IP:$PORT"
    
    # 3. POSTROUTING: Rewrite source IP for outgoing traffic from home server to appear as VPS
    echo "Adding POSTROUTING rule..."
    sudo iptables -t nat -A POSTROUTING -p tcp -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
    sudo iptables -t nat -A POSTROUTING -p udp -d "$HOME_SERVER_IP" --dport "$PORT" -j SNAT --to-source "$VPS_VPN_IP"
    
    # 4. FORWARD: Allow forwarded traffic through the firewall
    echo "Adding FORWARD rule..."
    sudo iptables -A FORWARD -p tcp -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    sudo iptables -A FORWARD -p udp -d "$HOME_SERVER_IP" --dport "$PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    
    # 5. MASQUERADE for general outgoing traffic from the VPN interface
    # This ensures that traffic originating from the VPN tunnel (e.g., your home server accessing the internet through the VPS)
    # is properly NATed to the VPS's public IP.
    echo "Adding MASQUERADE rule for VPN interface..."
    sudo iptables -t nat -A POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE
    
    # 6. Saving iptables
    echo "Saving iptables..."
    sudo netfilter-persistent save
    
    echo ""
    echo "--- Rules applied successfully! ---"
    echo ""
}

main() {
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