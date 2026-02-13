#!/bin/bash

# ==========================================
#  ICMP Tunnel Manager (GOST + WireGuard)
#  Optimized for High Censorship Environments
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# --- 1. Uninstall Function ---
function uninstall_all() {
    echo -e "${RED}[!] Cleaning up...${NC}"
    systemctl stop gost-icmp wg-quick@wg0 2>/dev/null
    systemctl disable gost-icmp wg-quick@wg0 2>/dev/null
    rm -f /etc/systemd/system/gost-icmp.service
    rm -f /etc/wireguard/wg0.conf
    rm -f /usr/local/bin/gost
    # Re-enable system ICMP
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all
    systemctl daemon-reload
    echo -e "${GREEN}[OK] All components removed.${NC}"
}

# --- 2. Install Function ---
function install_tunnel() {
    echo -e "${BLUE}[+] Installing Dependencies...${NC}"
    apt update && apt install -y wireguard-tools wget tar iproute2

    # Download GOST if not exists
    if [ ! -f "/usr/local/bin/gost" ]; then
        wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gunzip gost-linux-amd64-2.11.5.gz
        mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi

    echo -e "\n${YELLOW}Select Role:${NC}"
    echo "1) IRAN Server (Listener)"
    echo "2) KHAREJ Server (Initiator)"
    read -p "Option: " ROLE

    # WireGuard Keys
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

    if [ "$ROLE" == "1" ]; then
        # IRAN SIDE
        echo -e "${YELLOW}Enter Kharej Public Key:${NC}"
        read -p "Public Key: " PEER_PUB

        # Disable system ICMP to let GOST handle it
        echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all
        echo "echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all" >> /etc/rc.local 2>/dev/null

        # GOST Systemd
        cat > /etc/systemd/system/gost-icmp.service <<EOF
[Unit]
Description=GOST ICMP Server
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -L "icmp://:0/127.0.0.1:51820?mode=server"
Restart=always
[Install]
WantedBy=multi-user.target
EOF

        # WG Config
        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.10.10.1/30
ListenPort = 51820
PrivateKey = ${PRIV_KEY}
MTU = 1100
[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = 10.10.10.2/32
EOF

    else
        # KHAREJ SIDE
        read -p "Enter IRAN Server IP: " IRAN_IP
        echo -e "${YELLOW}Enter Iran Public Key:${NC}"
        read -p "Public Key: " PEER_PUB

        # GOST Systemd
        cat > /etc/systemd/system/gost-icmp.service <<EOF
[Unit]
Description=GOST ICMP Client
After=network.target
[Service]
ExecStart=/usr/local/bin/gost -L udp://:55555 -F "icmp://${IRAN_IP}:0?mode=client"
Restart=always
[Install]
WantedBy=multi-user.target
EOF

        # WG Config
        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.10.10.2/30
PrivateKey = ${PRIV_KEY}
MTU = 1100
[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = 10.10.10.1/32
Endpoint = 127.0.0.1:55555
PersistentKeepalive = 15
EOF
    fi

    systemctl daemon-reload
    systemctl enable gost-icmp wg-quick@wg0
    systemctl restart gost-icmp
    sleep 2
    systemctl restart wg-quick@wg0

    echo -e "\n${GREEN}====================================${NC}"
    echo -e "Your WireGuard IP: ${BLUE}10.10.10.${ROLE}${NC}"
    echo -e "Your Public Key:   ${YELLOW}${PUB_KEY}${NC}"
    echo -e "${GREEN}====================================${NC}"
}

# --- 3. Status Function ---
function check_status() {
    echo -e "\n${BLUE}--- GOST (ICMP) Status ---${NC}"
    systemctl status gost-icmp --no-pager
    echo -e "\n${BLUE}--- WireGuard Status ---${NC}"
    wg show
    echo -e "\n${BLUE}--- Connectivity Test ---${NC}"
    ping -c 2 10.10.10.1 2>/dev/null || ping -c 2 10.10.10.2 2>/dev/null
}

# --- Main Menu ---
clear
echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}    ICMP TUNNEL MANAGER (REVERSE)    ${NC}"
echo -e "${BLUE}=======================================${NC}"
echo "1. Install / Setup Tunnel"
echo "2. Check Status"
echo "3. Uninstall / Remove All"
echo "4. Exit"
read -p "Select [1-4]: " OPT

case $OPT in
    1) install_tunnel ;;
    2) check_status ;;
    3) uninstall_all ;;
    4) exit 0 ;;
    *) echo "Invalid option" ;;
esac