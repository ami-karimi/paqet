#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Check Root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo).${NC}"
  exit 1
fi

# --- 1. Install AmneziaWG if missing ---
if ! command -v awg &> /dev/null; then
    echo -e "${YELLOW}[!] AmneziaWG not found. Installing...${NC}"
    add-apt-repository ppa:amnezia/ppa -y
    apt-get update
    apt-get install -y amneziawg iptables iproute2
fi

# --- 2. Auto Key Generation (Robust Method) ---
mkdir -p /etc/amnezia
if [ ! -f /etc/amnezia/privatekey ]; then
    echo -e "${BLUE}[*] Generating Secure Keys...${NC}"
    # Creating keys using the tool directly
    awg genkey > /etc/amnezia/privatekey
    cat /etc/amnezia/privatekey | awg pubkey > /etc/amnezia/publickey
    chmod 600 /etc/amnezia/privatekey
fi

PRIV_KEY=$(cat /etc/amnezia/privatekey)
PUB_KEY=$(cat /etc/amnezia/publickey)

# --- 3. Interface IP Detection ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
LOCAL_IP_INTERFACE=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "${GREEN}Detected IP:${NC} $LOCAL_IP_INTERFACE on $INTERFACE"
echo -e "${GREEN}Your Public Key:${NC} $PUB_KEY"
echo -e "${YELLOW}-----------------------------------------${NC}"

# --- 4. Role Selection ---
echo -e "Which server is this?"
echo "1) Foreign Server (Germany/etc)"
echo "2) Iran Server (Bridge)"
read -p "Selection [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
    # --- FOREIGN CONFIG ---
    read -p "Enter Port (Default 51820): " WG_PORT
    WG_PORT=${WG_PORT:-51820}
    read -p "Enter Iran Public Key: " REMOTE_PUB

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
PublicKey = $REMOTE_PUB
AllowedIPs = 10.0.0.2/32, 172.16.1.0/30
EOF

    systemctl enable awg-quick@awg0
    systemctl restart awg-quick@awg0
    echo -e "${GREEN}SUCCESS: Foreign Server is Up!${NC}"

else
    # --- IRAN CONFIG ---
    read -p "Foreign Server Public IP: " F_IP
    read -p "Foreign Server Port (51820): " F_PORT
    F_PORT=${F_PORT:-51820}
    read -p "Foreign Server Public Key: " F_PUB
    read -p "MikroTik Public IP: " MK_IP
    read -p "GRE Local IP (172.16.1.1/30): " GRE_IP
    read -p "GRE Network (172.16.1.0/30): " GRE_NET

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
PublicKey = $F_PUB
Endpoint = $F_IP:$F_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Setup Script
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

    # Service
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
    echo -e "${GREEN}SUCCESS: Iran Bridge is Up!${NC}"
fi