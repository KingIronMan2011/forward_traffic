#!/bin/bash

set -e

get_user_input() {
    echo "We need some information to set up the Home Server for port forwarfing"
    echo ""
    while true; do
        read -p "Enter the public IP address of the VPS: " VPS_PUBLIC_IP
        if [[ $VPS_PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo "Invalid IP address format. Please try again."
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
    HOME_PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
    
    echo "Creating Wireguard Config File..."
    sudo tee /etc/wireguard/wg0.conf > /dev/null <<EOL
[Interface]
# Private IP address of the home server within the VPN tunnel
Address = 10.0.0.2/24
# Private key of the home server
PrivateKey = ${HOME_PRIVATE_KEY}
[Peer]
# Public key of the VPS
PublicKey = <Public_Key_of_VPS>
# The public IP address of the VPS and the listening port
Endpoint = ${VPS_PUBLIC_IP}:51820
# IP addresses allowed to be routed through this tunnel
AllowedIPs = 10.0.0.1/32
# Persist the connection if there is no traffic
PersistentKeepalive = 25
EOL
}

main() {
    get_user_input
    install_wireguard
    wireguard_setup
    
    echo "Home Server setup for port forwarding is complete."
    echo "Please ensure to replace <Public_Key_of_VPS> in the wg0.conf file."
    echo ""
    echo "After you set your key run the command 'wg-quick up wg0' and your done!"
}

main