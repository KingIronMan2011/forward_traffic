#!/bin/bash

# WireGuard / VPS Port Forwarding Script
# Supports single ports, port ranges, and IP ranges
# Author: ChatGPT (GPT-5)

check_dependencies() {
    echo "--- Checking dependencies ---"
    REQUIRED_COMMANDS=("netfilter-persistent" "iptables")
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "Error: '$cmd' is not installed. Installing it now..."
            sudo apt update -qq > /dev/null 2>&1
            sudo apt install -y -qq "$cmd" > /dev/null 2>&1
        fi
    done
    echo "✅ All dependencies are installed."
    echo ""
}

get_user_input() {
    echo "--- Port Forwarding Setup ---"
    echo "This script will configure iptables to forward traffic from your VPS to your home server."
    echo ""

    read -p "Enter your PUBLIC network interface (e.g., eth0, ens3): " PUBLIC_NETWORK_INTERFACE
    read -p "Enter your VPS VPN IP (e.g., 10.0.0.1): " VPS_VPN_IP
    read -p "Enter the HOME server IP or IP range (e.g., 10.0.0.2 or 10.0.0.2-10.0.0.10): " HOME_SERVER_IP
    read -p "Enter the port or port range to forward (e.g., 80 or 8000-8100): " PORT
    read -p "Enter the PROTOCOL (tcp, udp or all): " PROTOCOL

    # Validate protocol
    if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" && "$PROTOCOL" != "all" ]]; then
        echo "❌ Invalid protocol. Please enter 'tcp', 'udp', or 'all'."
        exit 1
    fi

    # Validate port or range
    if [[ "$PORT" =~ ^[0-9]+$ ]]; then
        :
    elif [[ "$PORT" =~ ^[0-9]+-[0-9]+$ ]]; then
        START_PORT=${PORT%-*}
        END_PORT=${PORT#*-}
        if (( START_PORT < 1 || END_PORT > 65535 || START_PORT > END_PORT )); then
            echo "❌ Invalid port range."
            exit 1
        fi
    else
        echo "❌ Invalid port or port range format."
        exit 1
    fi

    # Validate IP or range
    if [[ "$HOME_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        :
    elif [[ "$HOME_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        :
    else
        echo "❌ Invalid IP or IP range format."
        exit 1
    fi
}

apply_rules() {
    echo ""
    echo "--- Applying iptables rules ---"

    PORT_RANGE="${PORT/-/:}"              # Convert 8000-8100 → 8000:8100
    DEST_IP_RANGE="${HOME_SERVER_IP/-/:}" # Convert 10.0.0.2-10.0.0.10 → same (iptables supports this)

    echo "➡️ Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    echo "➡️ Adding NAT and FORWARD rules..."
    sudo iptables -t nat -A PREROUTING -p "$PROTOCOL" --dport "$PORT_RANGE" -j DNAT --to-destination "$DEST_IP_RANGE"
    sudo iptables -t nat -A POSTROUTING -p "$PROTOCOL" -d "$DEST_IP_RANGE" --dport "$PORT_RANGE" -j SNAT --to-source "$VPS_VPN_IP"
    sudo iptables -A FORWARD -p "$PROTOCOL" -d "$DEST_IP_RANGE" --dport "$PORT_RANGE" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    sudo iptables -t nat -A POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE

    echo "💾 Saving rules..."
    sudo netfilter-persistent save

    echo ""
    echo "✅ Rules applied successfully!"
    echo "Forwarding $PROTOCOL traffic on port(s) $PORT to $HOME_SERVER_IP"
    echo ""
}

apply_rules_all() {
    echo ""
    echo "--- Applying iptables rules (ALL protocols) ---"

    PORT_RANGE="${PORT/-/:}"
    DEST_IP_RANGE="${HOME_SERVER_IP/-/:}"

    echo "➡️ Enabling IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    for proto in tcp udp; do
        echo "➡️ Adding rules for $proto..."
        sudo iptables -t nat -A PREROUTING -p "$proto" --dport "$PORT_RANGE" -j DNAT --to-destination "$DEST_IP_RANGE"
        sudo iptables -t nat -A POSTROUTING -p "$proto" -d "$DEST_IP_RANGE" --dport "$PORT_RANGE" -j SNAT --to-source "$VPS_VPN_IP"
        sudo iptables -A FORWARD -p "$proto" -d "$DEST_IP_RANGE" --dport "$PORT_RANGE" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    done

    sudo iptables -t nat -A POSTROUTING -o "$PUBLIC_NETWORK_INTERFACE" -j MASQUERADE

    echo "💾 Saving rules..."
    sudo netfilter-persistent save

    echo ""
    echo "✅ Rules applied successfully!"
    echo "Forwarding TCP+UDP traffic on port(s) $PORT to $HOME_SERVER_IP"
    echo ""
}

main() {
    check_dependencies
    get_user_input
    
    if [[ "$PROTOCOL" = "tcp" ]]; then
        apply_rules
    elif [[ "$PROTOCOL" = "udp" ]]; then
        apply_rules
    elif [[ "$PROTOCOL" = "all" ]]; then
        apply_rules_all
    fi

    echo ""
    echo "--- Current iptables NAT table ---"
    sudo iptables -t nat -L -n -v
    echo ""
}

main
