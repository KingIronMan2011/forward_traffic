# Forward Traffic Setup

This project provides scripts to configure secure port forwarding between a VPS and a home server using WireGuard VPN. The goal is to forward traffic from your VPS to your home server, making services on your home network accessible via the VPS.

## Project Structure

- **`setup_home.sh`**: Sets up WireGuard on your home server.
- **`setup_vps.sh`**: Sets up WireGuard and forwarding on your VPS.
- **`forward_traffic.sh`**: (Optional) Script to help configure iptables rules for forwarding specific ports.

## Prerequisites

- A VPS running a Linux-based OS (e.g., Ubuntu).
- A home server running a Linux-based OS.
- Root or sudo access on both machines.
- Basic knowledge of Linux networking.

## Setup Instructions

### 1. Set Up the Home Server

1. Run the setup script:

   ```bash
   ./setup_home.sh
   ```

2. Follow the prompts:

   - Enter the public IP address of your VPS.
   - Enter the public key of your VPS (you can get this from `/etc/wireguard/publickey` on the VPS after running its setup).

3. Start WireGuard:

   ```bash
   sudo wg-quick up wg0
   ```

### 2. Set Up the VPS

1. Run the setup script:

   ```bash
   ./setup_vps.sh
   ```

2. Follow the prompts:

   - Enter the public network interface (e.g., `eth0`, `ens3`).
   - Enter the public key of your home server (from `/etc/wireguard/publickey` on the home server).

3. Start WireGuard:

   ```bash
   sudo wg-quick up wg0
   ```

### 3. (Optional) Forward Ports

If you want to forward specific ports from the VPS to your home server:

1. Run the forwarding script:

   ```bash
   ./forward_traffic.sh
   ```

2. The script supports multiple port forwarding formats:
   - **Single port**: `80`
   - **Port range**: `25565-25575` or `8000-9000`
   - **Comma-separated ports**: `80,443,8080`
   - **Semicolon-separated ports**: `80;443;8080`
   - **Combined**: `80,443,8000-8010,9000`

   Examples:

   ```txt
   Enter the port(s) to forward: 80
   Enter the port(s) to forward: 25565-26676
   Enter the port(s) to forward: 80,443,8080
   Enter the port(s) to forward: 80;443
   Enter the port(s) to forward: 80,443,8000-8010
   ```

## Verifying the Setup

- Check WireGuard status:

  ```bash
  sudo wg show
  ```

- Ensure the VPN tunnel is up and the peers are exchanging data.

## Troubleshooting

- Check WireGuard logs:

  ```bash
  sudo journalctl -u wg-quick@wg0
  ```

- Make sure the correct public keys and IPs are in each config.
- Ensure the VPS firewall allows UDP traffic on port 51820 (or your chosen WireGuard port).

## License

MIT License. See `LICENSE.md` for details.
