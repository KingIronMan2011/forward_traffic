#!/bin/bash

set -e

get_user_input() {
    echo "We need some information to set up the VPS for port forwarding."
    echo ""
    while true; do
        read -p "Enter the public network interface (e.g., eth0, ens3): " PUBLIC_NETWORK_INTERFACE
        if ip link show "$PUBLIC_NETWORK_INTERFACE" > /dev/null 2>&1; then
            break
        else
            echo "Invalid network interface. Please try again."
        fi
    done
}

install_wireguard() {
    echo "--- Install Wireguard ---"

    echo "Installing WireGuard..."
    sudo apt update -qq > /dev/null 2>&1
    sudo apt install -y -qq wireguard > /dev/null 2>&1
    echo "WireGuard installed successfully."

    echo "Creating Wireguard Directory..."
    sudo mkdir -p /etc/wireguard
}

wireguard_setup() {
    echo "Generating WireGuard keys..."
    sudo wg genkey | sudo tee /etc/wireguard/privatekey > /dev/null
    sudo cat /etc/wireguard/privatekey | sudo wg pubkey | sudo tee /etc/wireguard/publickey > /dev/null
    VPS_PRIVATE_KEY=$(cat /etc/wireguard/privatekey)

    echo "Creating Wireguard Config File..."
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOL
[Interface]
# Private IP address of the VPS within the VPN tunnel
Address = 10.0.0.1/24
# Private key of the VPS
PrivateKey = ${VPS_PRIVATE_KEY}
# Enable IP forwarding
PostUp = sysctl -w net.ipv4.ip_forward=1
# Enable NAT (Network Address Translation)
# This will forward traffic from the VPS's public IP to the home server
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE
# Disable IP forwarding and NAT on shutdown
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${PUBLIC_NETWORK_INTERFACE} -j MASQUERADE
# Listen port
ListenPort = 51820
[Peer]
# Public key of the home server
PublicKey = <Public_Key_of_Home_Server>
# IP address of the home server within the VPN tunnel
AllowedIPs = 10.0.0.2/32
EOL
}

activating_ip_forwarding() {
    echo "--- Activating IP Forwarding ---"
    sudo sysctl -w net.ipv4.ip_forward=1
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    echo "IP forwarding activated."
}

main() {
    get_user_input
    install_wireguard
    wireguard_setup
    activating_ip_forwarding

    echo "VPS setup for port forwarding is complete."
    echo "Please ensure to replace <Public_Key_of_Home_Server> in the wg0.conf file."
    echo ""
    echo "After you set your key run the command 'wg-quick up wg0' and your done!"
}

main