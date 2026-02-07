#!/bin/bash
# AmneziaWG + GRE Fully Automated Installer

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Function to get Local Interface IP ---
get_local_ip() {
    local_ip=$(ip -4 addr show $(ip route | grep default | awk '{print $5}' | head -n1) | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    echo "$local_ip"
}

LOCAL_IP_INTERFACE=$(get_local_ip)

echo -e "${BLUE}Detected Local IP: ${YELLOW}$LOCAL_IP_INTERFACE${NC}"
echo -e "${BLUE}Select Role:${NC}"
echo "1) Foreign Server (Server Mode)"
echo "2) Iran Server (Bridge Mode)"
read -p "Choice: " ROLE

# --- Auto Key Generation ---
mkdir -p /etc/amnezia
if [ ! -f /etc/amnezia/privatekey ]; then
    awg genkey | tee /etc/amnezia/privatekey | awg pubkey > /etc/amnezia/publickey
    chmod 600 /etc/amnezia/privatekey
fi

PRIV_KEY=$(cat /etc/amnezia/privatekey)
PUB_KEY=$(cat /etc/amnezia/publickey)

if [ "$ROLE" == "1" ]; then
    # --- FOREIGN SERVER ---
    read -p "Enter Port (Default 51820): " WG_PORT
    WG_PORT=${WG_PORT:-51820}
    read -p "Enter Iran Server Public Key: " IRAN_PUB_KEY

    cat <<EOF > /etc/amnezia/awg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.1/24
ListenPort = $WG_PORT
JunkPacketCount = 40
JunkPacketMinSize = 50
JunkPacketMaxSize = 1000
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

    echo -e "${GREEN}==============================================${NC}"
    echo -e "Foreign Server is UP!"
    echo -e "Your Public Key: ${YELLOW}$PUB_KEY${NC}"
    echo -e "Port: ${YELLOW}$WG_PORT${NC}"
    echo -e "${GREEN}==============================================${NC}"

else
    # --- IRAN SERVER ---
    read -p "Foreign Server Public IP: " FOREIGN_IP
    read -p "Foreign Server Port (Default 51820): " FOREIGN_PORT
    FOREIGN_PORT=${FOREIGN_PORT:-51820}
    read -p "Foreign Server Public Key: " FOREIGN_PUB_KEY
    read -p "MikroTik Public IP: " MK_IP
    read -p "GRE Local IP (e.g. 172.16.1.1/30): " GRE_IP
    read -p "GRE Network (e.g. 172.16.1.0/30): " GRE_NET

    cat <<EOF > /etc/amnezia/awg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.2/24
JunkPacketCount = 40
JunkPacketMinSize = 50
JunkPacketMaxSize = 1000
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

    cat <<EOF > /usr/local/bin/setup-bridge.sh
#!/bin/bash
awg-quick up awg0 2>/dev/null
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_IP local $LOCAL_IP_INTERFACE ttl 255
ip link set gre1 up
ip addr add $GRE_IP dev gre1
ip rule del from $GRE_NET table 100 2>/dev/null
ip route flush table 100
ip route add $GRE_NET dev gre1 table 100
ip route add default dev awg0 table 100
ip rule add from $GRE_NET table 100
iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

    chmod +x /usr/local/bin/setup-bridge.sh
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

    systemctl daemon-reload && systemctl enable mytunnel && systemctl start mytunnel

    echo -e "${GREEN}==============================================${NC}"
    echo -e "Iran Server is UP!"
    echo -e "Your Public Key: ${YELLOW}$PUB_KEY${NC}"
    echo -e "${GREEN}==============================================${NC}"
    echo -e "${BLUE}Copy this Public Key and use it when installing the Foreign Server.${NC}"
fi