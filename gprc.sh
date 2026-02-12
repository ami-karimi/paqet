#!/bin/bash

# GOST v3 Direct Tunnel (Custom Port)
# Features: Self-Signed TLS + gRPC + TUN Mode + Custom Port

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

install_gost() {
    if ! command -v gost &> /dev/null; then
        echo -e "${YELLOW}Downloading GOST v3...${NC}"
        wget https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz
        tar -zxvf gost_3.0.0_linux_amd64.tar.gz
        mv gost /usr/bin/gost
        chmod +x /usr/bin/gost
        rm gost_3.0.0_linux_amd64.tar.gz
        echo -e "${GREEN}GOST v3 Installed.${NC}"
    else
        echo -e "${GREEN}GOST is already installed.${NC}"
    fi
}

setup_service() {
    TYPE=$1

    echo -e "${YELLOW}Configuring Direct Tunnel...${NC}"

    if [ "$TYPE" == "server" ]; then
        # --- SERVER (KHAREJ) ---

        # 1. Ask for Port
        echo -e "Enter the Port you want to open (e.g., 443, 8443, 2087):"
        read -p "Port: " PORT
        [ -z "$PORT" ] && PORT=443

        # 2. Ask for Secret Path
        echo -e "Enter Secret Path (ServiceName)."
        read -p "Example (/MySecret): " WSPATH
        [ -z "$WSPATH" ] && WSPATH="/MySecret"

        # 3. Generate Fake SSL
        echo -e "${YELLOW}Generating Fake SSL Certificates...${NC}"
        mkdir -p /etc/gost
        openssl req -newkey rsa:2048 -nodes -keyout /etc/gost/key.pem -x509 -days 365 -out /etc/gost/cert.pem -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=www.google.com" 2>/dev/null

        # 4. Command
        CMD="/usr/bin/gost -L tun://:8421?net=10.10.10.1/24&name=tun0&mtu=1280 -L grpc://:$PORT?path=$WSPATH&certFile=/etc/gost/cert.pem&keyFile=/etc/gost/key.pem"

        # 5. Enable NAT & Firewall
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

        ufw allow $PORT/tcp 2>/dev/null
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
        echo -e "${GREEN}Port $PORT opened in firewall.${NC}"

    else
        # --- CLIENT (IRAN) ---
        read -p "Enter KHAREJ Server IP: " REMOTE_IP

        echo -e "Enter the Remote Port (Must match server!):"
        read -p "Port: " PORT
        [ -z "$PORT" ] && PORT=443

        echo -e "Enter Secret Path (Must match server!):"
        read -p "Example (/MySecret): " WSPATH
        [ -z "$WSPATH" ] && WSPATH="/MySecret"

        # Client connects to IP:PORT
        CMD="/usr/bin/gost -L tun://:8421?net=10.10.10.2/24&name=tun0&mtu=1280 -F grpc://$REMOTE_IP:$PORT?path=$WSPATH&secure=true&insecure=true"
    fi

    cat << EoS > /etc/systemd/system/gost_custom.service
[Unit]
Description=GOST Custom Tunnel
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
    systemctl enable gost_custom
    systemctl restart gost_custom

    echo -e "${GREEN}Installation Complete!${NC}"

    if [ "$TYPE" == "client" ]; then
        echo -e "------------------------------------------------"
        echo -e "Target: $REMOTE_IP:$PORT"
        echo -e "Wait 5 seconds, then ping: ${YELLOW}ping 10.10.10.1${NC}"
        echo -e "------------------------------------------------"
    fi
}

# --- MENU ---
clear
echo -e "${GREEN}GOST Direct Tunnel (Custom Port)${NC}"
echo "-----------------------------------"
echo "1) Install SERVER (Kharej)"
echo "2) Install CLIENT (Iran)"
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
        systemctl stop gost_custom
        systemctl disable gost_custom
        rm /etc/systemd/system/gost_custom.service
        rm /usr/bin/gost
        rm -rf /etc/gost
        echo "Removed."
        ;;
    4) exit ;;
    *) echo "Invalid" ;;
esac