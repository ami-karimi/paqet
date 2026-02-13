#!/bin/bash

# ==========================================
#  FakeTCP + WireGuard (amirmbn method based)
#  English Version - Auto Interface Setup
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Error: Must run as root${NC}"
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
    echo -e "${GREEN}Private Key:${NC} $PRIV"
    echo -e "${YELLOW}Public Key:${NC}  $PUB"
    echo -e "${BLUE}--------------------------------------------${NC}"
}

# --- Function: Uninstall ---
function uninstall_tunnel() {
    echo -e "${RED}[!] Uninstalling...${NC}"
    systemctl stop udp2raw wg-quick@wg0 2>/dev/null
    systemctl disable udp2raw wg-quick@wg0 2>/dev/null
    rm -f /etc/systemd/system/udp2raw.service
    rm -f /etc/wireguard/wg0.conf
    rm -f /usr/local/bin/udp2raw
    systemctl daemon-reload
    echo -e "${GREEN}[OK] Done.${NC}"
}

# --- Function: Install ---
function install_tunnel() {
    apt update && apt install -y wireguard-tools wget tar iptables

    # Download udp2raw
    if [ ! -f "/usr/local/bin/udp2raw" ]; then
        echo -e "${YELLOW}[+] Downloading udp2raw...${NC}"
        wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20230206.0/udp2raw_binaries.tar.gz
        tar -xzvf udp2raw_binaries.tar.gz > /dev/null
        cp udp2raw_amd64 /usr/local/bin/udp2raw
        chmod +x /usr/local/bin/udp2raw
        rm udp2raw_* version.txt 2>/dev/null
    fi

    echo -e "\n${BLUE}Select Role:${NC}"
    echo "1) IRAN (Server)"
    echo "2) KHAREJ (Client)"
    read -p "Role [1-2]: " ROLE

    read -p "Enter THIS server Private Key: " MY_PRIV
    read -p "Enter OPPOSITE server Public Key: " PEER_PUB
    read -p "Enter Tunnel Password (Shared): " TUN_PASS

    RAW_PORT=443 # Port used for FakeTCP

    if [ "$ROLE" == "1" ]; then
        # IRAN
        LOCAL_IP="10.10.10.1"
        PEER_IP="10.10.10.2"

        cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Server
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -s -l0.0.0.0:${RAW_PORT} -r 127.0.0.1:51820 -k "${TUN_PASS}" --raw-mode faketcp -a --keep-alive
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
MTU = 1200
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${PEER_IP}/32
EOF

    else
        # KHAREJ
        read -p "Enter IRAN Server Public IP: " IRAN_IP
        LOCAL_IP="10.10.10.2"
        PEER_IP="10.10.10.1"

        cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw Client
After=network.target

[Service]
ExecStart=/usr/local/bin/udp2raw -c -l127.0.0.1:51820 -r ${IRAN_IP}:${RAW_PORT} -k "${TUN_PASS}" --raw-mode faketcp -a --keep-alive
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${LOCAL_IP}/30
PrivateKey = ${MY_PRIV}
MTU = 1200

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${PEER_IP}/32
Endpoint = 127.0.0.1:51820
PersistentKeepalive = 15
EOF
    fi

    systemctl daemon-reload
    systemctl enable udp2raw wg-quick@wg0
    systemctl restart udp2raw
    sleep 3
    systemctl restart wg-quick@wg0
    echo -e "${GREEN}Tunnel Installed. Internal IP: ${LOCAL_IP}${NC}"
}

# --- Main Menu ---
clear
echo "1. Generate Keys"
echo "2. Setup Tunnel"
echo "3. Status"
echo "4. Uninstall"
read -p "Select: " OPT
case $OPT in
    1) generate_keys ;;
    2) install_tunnel ;;
    3) wg show; systemctl status udp2raw --no-pager ;;
    4) uninstall_tunnel ;;
esac