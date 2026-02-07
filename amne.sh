#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Root Check ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً با دسترسی root اجرا کنید.${NC}"
  exit 1
fi

# --- 1. Installation ---
echo -e "${BLUE}[*] نصب پیش‌نیازها و AmneziaWG...${NC}"
add-apt-repository ppa:amnezia/ppa -y
apt update
apt install -y linux-headers-$(uname -r) amneziawg amneziawg-tools iptables-persistent

# --- 2. Keys Generation ---
mkdir -p /etc/amnezia
if [ ! -f /etc/amnezia/privatekey ]; then
    awg genkey | tee /etc/amnezia/privatekey | awg pubkey > /etc/amnezia/publickey
    chmod 600 /etc/amnezia/privatekey
fi

PRIV_KEY=$(cat /etc/amnezia/privatekey)
PUB_KEY=$(cat /etc/amnezia/publickey)

# --- 3. Local IP Detection ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
LOCAL_IP=$(ip -4 addr show $INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "${YELLOW}-----------------------------------------${NC}"
echo -e "${GREEN}Detected IP:${NC} $LOCAL_IP"
echo -e "${GREEN}Your Public Key:${NC} $PUB_KEY"
echo -e "${YELLOW}-----------------------------------------${NC}"

# --- 4. Role Selection ---
echo -e "این سرور چه نقشی دارد؟"
echo "1) Foreign Server (خارج)"
echo "2) Iran Server (ایران + GRE)"
read -p "Selection [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
    # --- FOREIGN CONFIG ---
    read -p "Iran Public Key (کلید عمومی ایران را وارد کنید): " REMOTE_PUB
    read -p "Listen Port (Default 444): " PORT
    PORT=${PORT:-444}

    cat <<EOF > /etc/amnezia/awg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = 10.0.0.1/24
ListenPort = $PORT
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

    awg-quick up awg0 2>/dev/null
    systemctl enable awg-quick@awg0
    echo -e "${GREEN}سرور خارج با موفقیت راه اندازی شد.${NC}"

else
    # --- IRAN CONFIG ---
    read -p "Foreign Public IP (آی‌پی سرور خارج): " F_IP
    read -p "Foreign Port (444): " F_PORT
    F_PORT=${F_PORT:-444}
    read -p "Foreign Public Key (کلید عمومی سرور خارج): " F_PUB
    read -p "MikroTik Public IP (آی‌پی میکروتیک): " MK_IP
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

    # Setup Routing & GRE
    cat <<EOF > /usr/local/bin/setup-bridge.sh
#!/bin/bash
awg-quick up awg0 2>/dev/null
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_IP local $LOCAL_IP ttl 255
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

    systemctl daemon-reload
    systemctl enable mytunnel
    systemctl start mytunnel
    echo -e "${GREEN}پل ایران با موفقیت راه اندازی شد.${NC}"
fi

# Final Check
echo -e "${YELLOW}Status Check:${NC}"
awg show