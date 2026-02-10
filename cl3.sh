#!/bin/bash

# CloudTunnel Installer (GOST + WebSocket + Cloudflare CDN)
# Architecture: Iran -> Cloudflare (WSS) -> Kharej (WS)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

# 1. Install GOST
install_gost() {
    if ! command -v gost &> /dev/null; then
        echo -e "${YELLOW}Downloading GOST...${NC}"
        wget https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gunzip gost-linux-amd64-2.11.5.gz
        mv gost-linux-amd64-2.11.5 /usr/bin/gost
        chmod +x /usr/bin/gost
        echo -e "${GREEN}GOST Installed.${NC}"
    else
        echo -e "${GREEN}GOST is already installed.${NC}"
    fi
}

# 2. Configure Service
setup_service() {
    TYPE=$1

    echo -e "${YELLOW}Configuring Service...${NC}"

    if [ "$TYPE" == "server" ]; then
        # --- SERVER SIDE (KHAREJ) ---
        echo -e "Enter the WebSocket Path (Secret Path)."
        read -p "Example (/secret-chat): " WSPATH
        [ -z "$WSPATH" ] && WSPATH="/ws"

        # Server listens on port 8080 (Cloudflare connects here)
        # We use 'ws' (not wss) because Cloudflare handles the SSL termination.
        CMD="/usr/bin/gost -L ws://:8080?path=$WSPATH"

        # Enable NAT
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

        # Open Port 8080
        iptables -I INPUT -p tcp --dport 8080 -j ACCEPT

    else
        # --- CLIENT SIDE (IRAN) ---
        read -p "Enter your Cloudflare Domain (e.g., sub.domain.com): " DOMAIN

        echo -e "Enter the WebSocket Path (Must match server!):"
        read -p "Example (/secret-chat): " WSPATH
        [ -z "$WSPATH" ] && WSPATH="/ws"

        # Client connects to Cloudflare via WSS (Port 443)
        # Creates a TUN interface (tun0) with IP 10.10.10.2
        CMD="/usr/bin/gost -L tun://:8421?net=10.10.10.2/24&gateway=10.10.10.1 -F wss://$DOMAIN:443?path=$WSPATH"
    fi

    # Create Systemd Service
    cat << EoS > /etc/systemd/system/cloud_tunnel.service
[Unit]
Description=CloudTunnel Service
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=3
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EoS

    systemctl daemon-reload
    systemctl enable cloud_tunnel
    systemctl restart cloud_tunnel

    echo -e "${GREEN}Installation Complete!${NC}"

    if [ "$TYPE" == "client" ]; then
        echo -e "------------------------------------------------"
        echo -e "Tunnel is running!"
        echo -e "Test connection: ${YELLOW}ping 10.10.10.1${NC}"
        echo -e "------------------------------------------------"
    fi
}

# --- MENU ---
clear
echo -e "${GREEN}CloudTunnel Auto-Installer${NC}"
echo -e "${YELLOW}(Architecture: Iran > CDN > Kharej)${NC}"
echo "-----------------------------------"
echo "1) Install KHAREJ (Target Server)"
echo "2) Install IRAN (Client Server)"
echo "3) Uninstall"
echo "4) Exit"
echo "-----------------------------------"
read -p "Select: " opt

case $opt in
    1)
        install_gost
        setup_service "server"
        ;;
    2)
        install_gost
        setup_service "client"
        ;;
    3)
        systemctl stop cloud_tunnel
        systemctl disable cloud_tunnel
        rm /etc/systemd/system/cloud_tunnel.service
        rm /usr/bin/gost
        echo "Removed."
        ;;
    4) exit ;;
    *) echo "Invalid" ;;
esac