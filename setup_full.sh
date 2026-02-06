#!/bin/bash

# ====================================================
#   ULTIMATE PAQET + GRE + TUN2SOCKS MASTER SCRIPT
#   Version: Optimized for Hanselime Alpha (Raw Socket)
# ====================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 1. Root & Arch Check ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo).${NC}"
  exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo -e "${RED}Architecture $ARCH not supported.${NC}"
    exit 1
fi

# --- 2. Dependencies ---
echo -e "${BLUE}[+] Installing required tools...${NC}"
apt-get update -qq
apt-get install -y libpcap-dev iptables iptables-persistent net-tools curl wget tar unzip -qq
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf

# --- 3. Role Selection ---
echo -e "${YELLOW}-----------------------------------------${NC}"
echo -e "${YELLOW} SELECT SERVER ROLE:${NC}"
echo -e "1) Foreign Server (Server Mode)"
echo -e "2) Iran Server (Client Mode + GRE + Tun2Socks)"
echo -e "${YELLOW}-----------------------------------------${NC}"
read -p "Choice [1-2]: " ROLE

# --- 4. Network Auto-Detection ---
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
ping -c 1 $GW_IP > /dev/null 2>&1
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

# --- 5. Paqet Installation (Hanselime Alpha 14) ---
VERSION="v1.0.0-alpha.14"
FILE_NAME="paqet-linux-${PAQET_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/${FILE_NAME}"
INSTALL_PATH="/usr/local/bin/paqet"

echo -e "${BLUE}[+] Downloading Paqet $VERSION...${NC}"
wget -q --show-progress -O /tmp/paqet.tar.gz "$DOWNLOAD_URL"
mkdir -p /tmp/paqet_ext
tar -xzf /tmp/paqet.tar.gz -C /tmp/paqet_ext
BINARY=$(find /tmp/paqet_ext -type f -size +1M | head -n 1)
mv "$BINARY" $INSTALL_PATH
chmod +x $INSTALL_PATH
rm -rf /tmp/paqet_ext /tmp/paqet.tar.gz
mkdir -p /etc/paqet

# ====================================================
#   MODE 1: FOREIGN SERVER
# ====================================================
if [ "$ROLE" == "1" ]; then
    read -p "Paqet Port (e.g. 443): " P_PORT
    read -p "Tunnel Password: " P_KEY

    cat <<EOF > /etc/paqet/config.yaml
role: "server"
log: { level: "error" }
listen: { addr: ":$P_PORT" }
network:
  interface: "$IFACE"
  ipv4: { addr: "$LOCAL_IP:$P_PORT", router_mac: "$GW_MAC" }
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$P_KEY"
    mode: "fast3"
    sndwnd: 2048
    rcvwnd: 2048
    mtu: 1300
EOF

    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Server Service
After=network.target
[Service]
ExecStart=$INSTALL_PATH run -c /etc/paqet/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable paqet && systemctl restart paqet
    echo -e "${GREEN}Foreign Server is Ready!${NC}"
    exit 0
fi

# ====================================================
#   MODE 2: IRAN SERVER
# ====================================================
if [ "$ROLE" == "2" ]; then
    read -p "Foreign Server IP: " F_IP
    read -p "Foreign Server Port: " F_PORT
    read -p "Tunnel Password: " P_KEY
    read -p "MikroTik Public IP: " MK_IP
    read -p "GRE Local IP (e.g. 172.16.1.1/30): " GRE_IP
    read -p "GRE Network CIDR (e.g. 172.16.1.0/30): " GRE_NET

    # Install Tun2Socks
    echo -e "${BLUE}[+] Installing Tun2Socks...${NC}"
    wget -q -O /tmp/t2s.zip "https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-${PAQET_ARCH}.zip"
    unzip -q /tmp/t2s.zip -d /tmp/t2s_ext
    mv /tmp/t2s_ext/tun2socks-linux-${PAQET_ARCH} /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    rm -rf /tmp/t2s.zip /tmp/t2s_ext

    # Iran Paqet Config
    cat <<EOF > /etc/paqet/config.yaml
role: "client"
log: { level: "error" }
socks5:
  - listen: "127.0.0.1:1080"
network:
  interface: "$IFACE"
  ipv4: { addr: "$LOCAL_IP:0", router_mac: "$GW_MAC" }
server: { addr: "$F_IP:$F_PORT" }
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$P_KEY"
    mode: "fast3"
    sndwnd: 2048
    rcvwnd: 2048
    mtu: 1300
EOF

    # Network Logic Script
    cat <<EOF > /usr/local/bin/setup-tunnel.sh
#!/bin/bash
# GRE + Tun2Socks Logic
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_IP local $LOCAL_IP ttl 255
ip link set gre1 up
ip addr add $GRE_IP dev gre1

ip tuntap add dev tun0 mode tun
ip link set tun0 up
ip addr add 10.0.0.1/24 dev tun0

ip rule del from $GRE_NET table 100 2>/dev/null
ip route flush table 100
ip route add $GRE_NET dev gre1 table 100
ip route add default dev tun0 table 100
ip rule add from $GRE_NET table 100
ip rule add to $GRE_NET lookup main priority 10

iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i gre1 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o gre1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

/usr/local/bin/tun2socks -device tun0 -proxy socks5://127.0.0.1:1080 -udp-timeout 1m
EOF
    chmod +x /usr/local/bin/setup-tunnel.sh

    # Systemd Services
    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
After=network.target
[Service]
ExecStart=$INSTALL_PATH run -c /etc/paqet/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/mytunnel.service
[Unit]
After=network.target paqet.service
[Service]
ExecStart=/usr/local/bin/setup-tunnel.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable paqet mytunnel
    systemctl restart paqet && sleep 2 && systemctl restart mytunnel
    echo -e "${GREEN}Iran Server is Ready! Configured for Full Speed.${NC}"
fi