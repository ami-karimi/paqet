#!/bin/bash

# ==========================================
#  Reverse Tunnel Manager: WireGuard + udp2raw
#  Features: Install, Uninstall, Status Check
# ==========================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   exit 1
fi

# --- Uninstall Function ---
function uninstall_tunnel() {
    echo -e "\n${RED}[!] Starting Uninstallation...${NC}"

    # 1. Stop Services
    echo "Stopping services..."
    systemctl stop udp2raw > /dev/null 2>&1
    systemctl stop wg-quick@wg0 > /dev/null 2>&1
    systemctl disable udp2raw > /dev/null 2>&1
    systemctl disable wg-quick@wg0 > /dev/null 2>&1

    # 2. Remove Files
    echo "Removing files..."
    rm -f /usr/local/bin/udp2raw
    rm -f /etc/systemd/system/udp2raw.service
    rm -f /etc/wireguard/wg0.conf

    # 3. Reload Daemons
    systemctl daemon-reload
    systemctl reset-failed

    echo -e "${GREEN}[OK] Uninstallation Complete.${NC}"
    echo "WireGuard tools (packages) were NOT removed to avoid breaking other tools."
    echo "You can remove them manually with: apt remove wireguard-tools"
}

# --- Install Function ---
function install_tunnel() {
    # 1. Dependencies
    echo -e "${BLUE}[+] Installing Dependencies...${NC}"
    if [ -f /etc/debian_version ]; then
        apt-get update -y && apt-get install -y wireguard-tools iptables wget tar
    elif [ -f /etc/redhat-release ]; then
        yum install -y wireguard-tools iptables wget tar
    fi

    # Enable IP Forwarding
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi

    # 2. Download udp2raw
    if [ ! -f "/usr/local/bin/udp2raw" ]; then
        echo -e "${YELLOW}[+] Downloading udp2raw...${NC}"
        ARCH=$(uname -m)
        wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20230206.0/udp2raw_binaries.tar.gz
        tar -xzvf udp2raw_binaries.tar.gz > /dev/null

        if [[ "$ARCH" == "x86_64" ]]; then
            cp udp2raw_amd64 /usr/local/bin/udp2raw
        elif [[ "$ARCH" == "aarch64" ]]; then
            cp udp2raw_arm /usr/local/bin/udp2raw
        else
            cp udp2raw_x86 /usr/local/bin/udp2raw
        fi

        chmod +x /usr/local/bin/udp2raw
        rm udp2raw_* udp2raw_binaries.tar.gz version.txt 2>/dev/null
    fi

    # 3. Role Selection
    echo -e "\n${BLUE}--- Configuration ---${NC}"
    echo "1) IRAN Server (Destination / Listener)"
    echo "2) KHAREJ Server (Source / Initiator)"
    read -p "Select Role [1-2]: " ROLE

    # Generate Keys
    PRIV_KEY=$(wg genkey)
    PUB_KEY=$(echo "$PRIV_KEY" | wg pubkey)

    read -p "Enter Tunnel Password (Shared Secret): " RAW_PASS

    if [ "$ROLE" == "1" ]; then
        # IRAN
        LOCAL_IP="10.10.10.1"
        PEER_IP="10.10.10.2"
        echo -e "\n${YELLOW}Enter Public Key of KHAREJ Server:${NC}"
        read -p "Key: " PEER_PUB_KEY

        # udp2raw Service (Server)
        cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Server
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -s -l0.0.0.0:443 -r 127.0.0.1:51820 -k "${RAW_PASS}" --raw-mode faketcp -a --keep-alive
Restart=always
RestartSec=3
EOF

        # WG Config
        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${LOCAL_IP}/30
ListenPort = 51820
PrivateKey = ${PRIV_KEY}
MTU = 1200
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB_KEY}
AllowedIPs = ${PEER_IP}/32
EOF

    elif [ "$ROLE" == "2" ]; then
        # KHAREJ
        LOCAL_IP="10.10.10.2"
        PEER_IP="10.10.10.1"
        read -p "Enter IRAN Server IP: " IRAN_REAL_IP
        echo -e "\n${YELLOW}Enter Public Key of IRAN Server:${NC}"
        read -p "Key: " PEER_PUB_KEY

        # udp2raw Service (Client)
        cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Client
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l127.0.0.1:55555 -r ${IRAN_REAL_IP}:443 -k "${RAW_PASS}" --raw-mode faketcp -a --keep-alive
Restart=always
RestartSec=3
EOF

        # WG Config
        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${LOCAL_IP}/30
PrivateKey = ${PRIV_KEY}
MTU = 1200
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = 127.0.0.1:55555
PersistentKeepalive = 15
EOF
    fi

    # Start
    systemctl daemon-reload
    systemctl enable udp2raw wg-quick@wg0
    systemctl restart udp2raw wg-quick@wg0

    echo -e "\n${GREEN}[OK] Setup Complete!${NC}"
    echo -e "Your IP: ${BLUE}${LOCAL_IP}${NC}"
    echo -e "Your Public Key: ${YELLOW}${PUB_KEY}${NC}"
    echo "PLEASE COPY THIS KEY to the other server."
}

# --- Main Menu ---
clear
echo -e "${BLUE}=================================${NC}"
echo -e "${GREEN}   Tunnel Manager (FakeTCP)   ${NC}"
echo -e "${BLUE}=================================${NC}"
echo "1. Install Tunnel"
echo "2. Uninstall Tunnel"
echo "3. Check Status"
echo "4. Exit"
read -p "Choose option [1-4]: " OPTION

case $OPTION in
    1) install_tunnel ;;
    2) uninstall_tunnel ;;
    3)
       echo -e "\n--- udp2raw Status ---"
       systemctl status udp2raw --no-pager
       echo -e "\n--- WireGuard Status ---"
       wg show
       ;;
    4) exit 0 ;;
    *) echo "Invalid option"; exit 1 ;;
esac