#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}    Cloudflare WebSocket Tunnel Setup    ${NC}"
echo -e "${GREEN}           Powered by GOST               ${NC}"
echo -e "${GREEN}=========================================${NC}"

# Install Dependencies
apt-get update -y > /dev/null 2>&1
apt-get install wget tar nano -y > /dev/null 2>&1

# Install GOST function
install_gost() {
    if ! command -v gost &> /dev/null; then
        echo -e "${YELLOW}Downloading GOST...${NC}"
        wget -N --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gunzip -f gost-linux-amd64-2.11.5.gz
        mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
        echo -e "${GREEN}GOST installed successfully.${NC}"
    else
        echo -e "${GREEN}GOST is already installed.${NC}"
    fi
}

setup_kharej() {
    echo -e "${YELLOW}--- Configuring FOREIGN Server (Destination) ---${NC}"
    read -p "Enter Port to listen on (Default 8080): " PORT
    PORT=${PORT:-8080}
    read -p "Enter a Username for authentication: " USER
    read -p "Enter a Password for authentication: " PASS

    # Cloudflare HTTP ports: 80, 8080, 8880, 2052, 2082, 2086, 2095
    # We use ws (plain websocket) because CF handles SSL termination
    CMD="/usr/local/bin/gost -L=\"ws://${USER}:${PASS}@:${PORT}?path=/ws\""

    create_service "$CMD"
    echo -e "${GREEN}Done! Make sure Cloudflare SSL is set to 'Flexible' or 'Full'.${NC}"
    echo -e "${GREEN}Ensure port ${PORT} is open in your firewall.${NC}"
}

setup_iran() {
    echo -e "${YELLOW}--- Configuring IRAN Server (Client) ---${NC}"
    read -p "Enter Your Domain (e.g., sub.example.com): " DOMAIN
    read -p "Enter Username (configured on Kharej): " USER
    read -p "Enter Password (configured on Kharej): " PASS
    read -p "Enter Local Port to Open on Iran (e.g., 9090): " LOCAL_PORT
    read -p "Enter Final Destination IP (Where traffic goes after Kharej): " DEST_IP
    read -p "Enter Final Destination Port: " DEST_PORT

    # Connect via WSS (443) to Cloudflare, which forwards to Kharej
    CMD="/usr/local/bin/gost -L=tcp://:${LOCAL_PORT}/${DEST_IP}:${DEST_PORT} -F=\"wss://${USER}:${PASS}@${DOMAIN}:443?path=/ws\""

    create_service "$CMD"
    echo -e "${GREEN}Tunnel Established!${NC}"
    echo -e "Connect to ${YELLOW}${LOCAL_PORT}${NC} on this server to reach ${YELLOW}${DEST_IP}:${DEST_PORT}${NC}"
}

create_service() {
    CMD=$1
    echo -e "${YELLOW}Creating Systemd Service...${NC}"
    cat > /etc/systemd/system/gost.service <<EOF
[Unit]
Description=GOST Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CMD
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost
    systemctl restart gost
    systemctl status gost --no-pager
}

# Main Menu
install_gost

echo "Select Role:"
echo "1) Foreign Server (Kharej - Receiver)"
echo "2) Iran Server (Iran - Sender)"
read -p "Select [1-2]: " CHOICE

case $CHOICE in
    1) setup_kharej ;;
    2) setup_iran ;;
    *) echo "Invalid option"; exit 1 ;;
esac