#!/bin/bash
# AmneziaWG + GRE Master Installer (Local IP Detection)

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Function to get Local Interface IP ---
get_local_ip() {
    # Finds the IP of the interface that has the default gateway
    local_ip=$(ip -4 addr show $(ip route | grep default | awk '{print $5}' | head -n1) | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    echo "$local_ip"
}

# Get IP from Ethernet Interface
LOCAL_IP_INTERFACE=$(get_local_ip)

echo -e "${BLUE}Detected Local IP on Interface: ${YELLOW}$LOCAL_IP_INTERFACE${NC}"

echo -e "${BLUE}Select Role:${NC}"
echo "1) Foreign Server (Server)"
echo "2) Iran Server (Bridge to MikroTik)"
read -p "Choice: " ROLE

# Generate Keys
if [ ! -f /etc/amnezia/privatekey ]; then
    mkdir -p /etc/amnezia
    awg genkey | tee /etc/amnezia/privatekey | awg pubkey > /etc/amnezia/publickey
fi

PRIV_KEY=$(cat /etc/amnezia/privatekey)
PUB_KEY=$(cat /etc/amnezia/publickey)

if [ "$ROLE" == "1" ]; then
    # --- FOREIGN SERVER ---
    echo -e "${GREEN}Configuring Foreign Server...${NC}"
    echo -e "${YELLOW}Your Public Key: ${NC}$PUB_KEY"
    read -p "Enter Port (e.g., 51820): " WG_PORT
    read -p "Enter Iran Server Public Key: " IRAN_PUB_KEY

    cat <<EOF > /etc/amnezia/awg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.1/24
ListenPort = $WG_PORT
JunkPacketCount = 40
JunkPacketMinSize = 50
JunkPacketMaxSize = 1000
InitPacketJunkSize = 0
ResponsePacketJunkSize = 0
InitPacketMagicHeader = 0x01020304
ResponsePacketMagicHeader = 0x05060708
UnderloadPacketMagicHeader = 0x090a0b0c
TransportPacketMagicHeader = 0x0d0e0f10

[Peer]
PublicKey = $IRAN_PUB_KEY
AllowedIPs = 10.0.0.2/32, 172.16.1.0/30
EOF

    systemctl enable awg-quick@awg0
    systemctl restart awg-quick@awg0
    echo -e "${GREEN}Foreign Server is UP!${NC}"

else
    # --- IRAN SERVER ---
    echo -e "${GREEN}Configuring Iran Server...${NC}"
    echo -e "${YELLOW}Your Public Key: ${NC}$PUB_KEY"
    read -p "Enter Foreign Server Public IP: " FOREIGN_IP
    read -p "Enter Foreign Server Port: " FOREIGN_PORT
    read -p "Enter Foreign Server Public Key: " FOREIGN_PUB_KEY
    read -p "Enter MikroTik Public IP: " MK_IP
    read -p "Enter GRE Local IP (e.g., 172.16.1.1/30): " GRE_IP
    read -p "Enter GRE Network (e.g., 172.16.1.0/30): " GRE_NET

    # 1. Setup AmneziaWG
    cat <<EOF > /etc/amnezia/awg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.2/24
JunkPacketCount = 40
JunkPacketMinSize = 50
JunkPacketMaxSize = 1000
InitPacketJunkSize = 0
ResponsePacketJunkSize = 0
InitPacketMagicHeader = 0x01020304
ResponsePacketMagicHeader = 0x05060708
UnderloadPacketMagicHeader = 0x090a0b0c
TransportPacketMagicHeader = 0x0d0e0f10

[Peer]
PublicKey = $FOREIGN_PUB_KEY
Endpoint = $FOREIGN_IP:$FOREIGN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # 2. Setup GRE & Routing Script
    # Using the detected Interface IP for GRE
    cat <<EOF > /usr/local/bin/setup-bridge.sh
#!/bin/bash
# Start AmneziaWG
awg-quick up awg0 2>/dev/null

# Setup GRE
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_IP local $LOCAL_IP_INTERFACE ttl 255
ip link set gre1 up
ip addr add $GRE_IP dev gre1

# Routing
ip rule del from $GRE_NET table 100 2>/dev/null
ip route flush table 100
ip route add $GRE_NET dev gre1 table 100
ip route add default dev awg0 table 100
ip rule add from $GRE_NET table 100

# NAT & MSS
iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

    chmod +x /usr/local/bin/setup-bridge.sh

    # Service for Bridge
    cat <<EOF > /etc/systemd/system/mytunnel.service
[Unit]
After=network.target
[Service]
ExecStart=/usr/local/bin/setup-bridge.sh
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mytunnel
    systemctl start mytunnel
    echo -e "${GREEN}Iran Bridge is UP! Running on Kernel level (Low CPU).${NC}"
fi