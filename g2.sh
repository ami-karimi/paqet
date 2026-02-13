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

# --- Function: Generate Keys ---
function generate_keys() {
    echo -e "${BLUE}[+] Generating WireGuard Keys...${NC}"
    if ! command -v wg &> /dev/null; then
        apt update && apt install -y wireguard-tools
    fi
    PRIV=$(wg genkey)
    PUB=$(echo "$PRIV" | wg pubkey)
    echo -e "${GREEN}Your Private Key:${NC} $PRIV"
    echo -e "${YELLOW}Your Public Key:${NC}  $PUB"
    echo -e "${BLUE}--------------------------------------------${NC}"
    echo -e "Copy these keys. You will need them during the installation."
}

# --- Function: Uninstall ---
function uninstall_tunnel() {
    echo -e "${RED}[!] Starting Uninstallation...${NC}"
    systemctl stop gost-icmp wg-quick@wg0 2>/dev/null
    systemctl disable gost-icmp wg-quick@wg0 2>/dev/null
    rm -f /etc/systemd/system/gost-icmp.service
    rm -f /etc/wireguard/wg0.conf
    rm -f /usr/local/bin/gost
    # Re-enable system ICMP response
    echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all
    systemctl daemon-reload
    echo -e "${GREEN}[OK] Cleanup complete.${NC}"
}

# --- Function: Install ---
function install_tunnel() {
    echo -e "${BLUE}[+] Installing Dependencies...${NC}"
    apt update && apt install -y wireguard-tools wget tar iproute2 net-tools

    if [ ! -f "/usr/local/bin/gost" ]; then
        echo -e "${YELLOW}[+] Downloading GOST...${NC}"
        wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gunzip gost-linux-amd64-2.11.5.gz
        mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    fi

    echo -e "\n${BLUE}Select Server Role:${NC}"
    echo "1) IRAN Server (Listener / Receiver)"
    echo "2) KHAREJ Server (Initiator / Sender)"
    read -p "Option [1-2]: " ROLE

    echo -e "\n${YELLOW}Configuration Data Needed:${NC}"
    read -p "Enter THIS server's Private Key: " MY_PRIV
    read -p "Enter OPPOSITE server's Public Key: " PEER_PUB

    if [ "$ROLE" == "1" ]; then
        # IRAN SETTINGS
        LOCAL_IP="10.10.10.1"
        PEER_IP="10.10.10.2"
        # Disable OS ICMP reply to allow GOST to handle pings
        echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_all

        cat > /etc/systemd/system/gost-icmp.service <<EOF
[Unit]
Description=GOST ICMP Tunnel Server
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L "icmp://:0/127.0.0.1:51820?mode=server"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${LOCAL_IP}/30
ListenPort = 51820
PrivateKey = ${MY_PRIV}
MTU = 1100
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${PEER_IP}/32
EOF

    else
        # KHAREJ SETTINGS
        read -p "Enter IRAN Server Public IP: " IRAN_IP
        LOCAL_IP="10.10.10.2"
        PEER_IP="10.10.10.1"

        cat > /etc/systemd/system/gost-icmp.service <<EOF
[Unit]
Description=GOST ICMP Tunnel Client
After=network.target

[Service]
ExecStart=/usr/local/bin/gost -L udp://:55555 -F "icmp://${IRAN_IP}:0?mode=client"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${LOCAL_IP}/30
PrivateKey = ${MY_PRIV}
MTU = 1100
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${PEER_IP}/32
Endpoint = 127.0.0.1:55555
PersistentKeepalive = 15
EOF
    fi

    echo -e "${YELLOW}[+] Starting services...${NC}"
    systemctl daemon-reload
    systemctl enable gost-icmp wg-quick@wg0
    systemctl restart gost-icmp
    sleep 3
    systemctl restart wg-quick@wg0

    echo -e "\n${GREEN}===============================================${NC}"
    echo -e "  TUNNEL INSTALLED SUCCESSFULLY"
    echo -e "  Internal IP: ${BLUE}${LOCAL_IP}${NC}"
    echo -e "===============================================${NC}"
}

# --- Main Menu ---
clear
echo -e "${BLUE}===============================================${NC}"
echo -e "${GREEN}       ICMP TUNNEL MANAGER (ENGLISH)         ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo "1. Generate WG Keys (Do this first on both)"
echo "2. Install / Setup Tunnel"
echo "3. Check Tunnel Status"
echo "4. Uninstall / Remove Tunnel"
echo "5. Exit"
read -p "Select an option [1-5]: " OPT

case $OPT in
    1) generate_keys ;;
    2) install_tunnel ;;
    3)
       echo -e "\n${YELLOW}--- WireGuard Status ---${NC}"
       wg show
       echo -e "\n${YELLOW}--- GOST Log (Last 5 lines) ---${NC}"
       journalctl -u gost-icmp -n 5 --no-pager
       ;;
    4) uninstall_tunnel ;;
    5) exit 0 ;;
    *) echo "Invalid option" ;;
esac