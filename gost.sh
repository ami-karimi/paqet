#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root!${NC}"
   exit 1
fi

# Optimization Function
optimize_sysctl() {
    echo -e "${YELLOW}Optimizing network settings (BBR & Buffers)...${NC}"

    # Enable BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    # Increase UDP/TCP buffers for high speed
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
EOF
    sysctl -p
    echo -e "${GREEN}Optimization complete!${NC}"
}

# Install Gost Function
install_gost() {
    if ! command -v gost &> /dev/null; then
        echo -e "${YELLOW}Downloading and installing GOST v3...${NC}"
        bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh)
        mv /usr/local/bin/gost /usr/bin/gost
        echo -e "${GREEN}GOST installed successfully.${NC}"
    else
        echo -e "${GREEN}GOST is already installed.${NC}"
    fi

    # Install dependencies
    apt update && apt install -y openssl wget
}

# Remote Server Setup (Kharej)
setup_remote() {
    echo -e "${CYAN}--- Remote Server Setup (Kharej) ---${NC}"
    read -p "Enter Listen Port (Default 443): " PORT
    PORT=${PORT:-443}

    read -p "Enter Tunnel Password: " PASS

    read -p "Enter Fake Path (Default /chat): " PATH_FAKE
    PATH_FAKE=${PATH_FAKE:-/chat}

    # Generate Fake SSL Cert
    echo -e "${YELLOW}Generating fake SSL certificate to bypass DPI...${NC}"
    mkdir -p /etc/gost
    openssl req -newkey rsa:2048 -nodes -keyout /etc/gost/key.pem -x509 -days 3650 -out /etc/gost/cert.pem -subj "/C=US/ST=California/L=SanFrancisco/O=Google/CN=www.google.com" &> /dev/null

    # Create Service
    cat > /etc/systemd/system/gost-tunnel.service <<EOF
[Unit]
Description=GOST Tunnel Server
After=network.target

[Service]
ExecStart=/usr/bin/gost -L "tun://:8421?net=10.10.10.1/24&name=tun0&mtu=1350" -L "mwss://admin:${PASS}@:${PORT}?cert=/etc/gost/cert.pem&key=/etc/gost/key.pem&path=${PATH_FAKE}"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost-tunnel
    systemctl restart gost-tunnel

    optimize_sysctl

    echo -e "${GREEN}✅ Setup Complete!${NC}"
    echo -e "Tunnel IP (Remote): ${CYAN}10.10.10.1${NC}"
    echo -e "Now run option 2 on your Iran server."
}

# Local Server Setup (Iran)
setup_local() {
    echo -e "${CYAN}--- Local Server Setup (Iran) ---${NC}"
    read -p "Enter Remote Server IP: " REMOTE_IP

    read -p "Enter Remote Server Port (Default 443): " REMOTE_PORT
    REMOTE_PORT=${REMOTE_PORT:-443}

    read -p "Enter Tunnel Password: " PASS

    read -p "Enter Fake Path (Default /chat): " PATH_FAKE
    PATH_FAKE=${PATH_FAKE:-/chat}

    # Create Service
    cat > /etc/systemd/system/gost-tunnel.service <<EOF
[Unit]
Description=GOST Tunnel Client
After=network.target

[Service]
ExecStart=/usr/bin/gost -L "tun://:8421?net=10.10.10.2/24&name=tun0&mtu=1350&gateway=10.10.10.1" -F "mwss://admin:${PASS}@${REMOTE_IP}:${REMOTE_PORT}?path=${PATH_FAKE}&nodelay=true"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost-tunnel
    systemctl restart gost-tunnel

    optimize_sysctl

    echo -e "${GREEN}✅ Setup Complete!${NC}"
    echo -e "Tunnel IP (Local): ${CYAN}10.10.10.2${NC}"
    echo -e "Test connection: ping 10.10.10.1"
}

# Remove Function
remove_tunnel() {
    systemctl stop gost-tunnel
    systemctl disable gost-tunnel
    rm /etc/systemd/system/gost-tunnel.service
    rm -rf /etc/gost
    systemctl daemon-reload
    echo -e "${RED}Tunnel service removed successfully.${NC}"
}

# Main Menu
clear
echo -e "${CYAN}=================================${NC}"
echo -e "${CYAN}   Advanced GOST Tunnel Script   ${NC}"
echo -e "${CYAN}=================================${NC}"
echo -e "1) Install Remote Server (Kharej)"
echo -e "2) Install Local Server (Iran)"
echo -e "3) Remove Tunnel"
echo -e "0) Exit"
echo -e "${CYAN}=================================${NC}"
read -p "Select an option: " CHOICE

case $CHOICE in
    1)
        install_gost
        setup_remote
        ;;
    2)
        install_gost
        setup_local
        ;;
    3)
        remove_tunnel
        ;;
    0)
        exit 0
        ;;
    *)
        echo "Invalid option."
        ;;
esac