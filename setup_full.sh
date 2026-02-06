#!/bin/bash

# ====================================================
#   ULTIMATE INSTALLER: PAQET (Custom Ver) + GRE + TUN2SOCKS
# ====================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 1. Check Root & Dependencies ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo bash install.sh)${NC}"
  exit 1
fi

echo -e "${BLUE}[+] Installing Dependencies...${NC}"
apt-get update -qq
apt-get install -y curl wget unzip iptables iproute2 tar net-tools -qq
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf

# --- 2. Architecture Detection ---
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo -e "${RED}Architecture $ARCH not supported.${NC}"
    exit 1
fi

# --- 3. Role Selection ---
echo -e "${YELLOW}-----------------------------------------${NC}"
echo -e "${YELLOW} WHICH SERVER IS THIS?${NC}"
echo -e "1) Foreign Server (Server Mode)"
echo -e "2) Iran Server (Client Mode + GRE + Tun2Socks)"
echo -e "${YELLOW}-----------------------------------------${NC}"
read -p "Select [1 or 2]: " SERVER_ROLE

# --- 4. Install Paqet (CUSTOM VERSION LOGIC) ---
VERSION="v1.0.0-alpha.14"
FILE_NAME="paqet-linux-${PAQET_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/${FILE_NAME}"
TEMP_DIR="/tmp/paqet_install"

echo -e "${BLUE}[+] Downloading Paqet (${VERSION})...${NC}"

# Clean start
rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR
rm -f /tmp/paqet.tar.gz

# Download
wget -q --show-progress -O /tmp/paqet.tar.gz "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}[Error] Download failed. Check URL or Internet.${NC}"
    exit 1
fi

# Extract
echo -e "${BLUE}[+] Extracting...${NC}"
tar -xzf /tmp/paqet.tar.gz -C $TEMP_DIR

# Find binary (Smart Find)
BINARY_FOUND=$(find $TEMP_DIR -type f -size +1M | head -n 1)

if [ -n "$BINARY_FOUND" ]; then
    echo -e "${GREEN}[+] Binary found: $BINARY_FOUND${NC}"
    mv "$BINARY_FOUND" /usr/local/bin/paqet
    chmod +x /usr/local/bin/paqet
else
    echo -e "${RED}[Error] Binary not found in archive!${NC}"
    exit 1
fi

# Cleanup
rm -rf $TEMP_DIR /tmp/paqet.tar.gz
mkdir -p /etc/paqet


# ====================================================
#   MODE 1: FOREIGN SERVER
# ====================================================
if [ "$SERVER_ROLE" == "1" ]; then
    echo -e "${GREEN}>>> Configuring Foreign Server <<<${NC}"

    read -p "Enter Port for Paqet to Listen (e.g., 443): " P_PORT
    read -p "Enter Encryption Key (Password): " P_KEY

    # Get Gateway MAC automatically if not provided
        GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
        # Ping to ensure ARP table is populated
        ping -c 1 $GW_IP > /dev/null 2>&1
        DETECTED_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
        INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# Get Gateway MAC automatically if not provided
    GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
    # Ping to ensure ARP table is populated
    ping -c 1 $GW_IP > /dev/null 2>&1
    DETECTED_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

    cat <<EOF > /etc/paqet/config.yaml
role: "server"
log: { level: "error" }
listen: { addr: ":$P_PORT" }
network:
  interface: "$INTERFACE"
  ipv4: { addr: "$LOCAL_PUB_IP:$P_PORT", router_mac: "$DETECTED_MAC" }
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

    # Service
    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Server
After=network.target
[Service]
ExecStart=/usr/local/bin/paqet -config /etc/paqet/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable paqet
    systemctl restart paqet

    echo -e "${GREEN}SUCCESS! Foreign Server is ready on port $P_PORT.${NC}"
    exit 0
fi

# ====================================================
#   MODE 2: IRAN SERVER (THE FULL PACKAGE)
# ====================================================
if [ "$SERVER_ROLE" == "2" ]; then
    echo -e "${GREEN}>>> Configuring Iran Server (GRE + Tun2Socks) <<<${NC}"

    # --- Inputs ---
    echo -e "${YELLOW}--- Paqet Connection Info ---${NC}"
    read -p "Foreign Server IP: " REMOTE_IP
    read -p "Foreign Server Port: " REMOTE_PORT
    read -p "Encryption Key: " P_KEY

    echo -e "${YELLOW}--- GRE Tunnel Info ---${NC}"
    read -p "MikroTik Public IP: " MIKROTIK_IP
    read -p "GRE Local IP (e.g., 172.16.1.1/30): " GRE_LOCAL
    # Calculate Network
    echo -e "Enter GRE Network CIDR (e.g., 172.16.1.0/30): "
    read -p "GRE Network CIDR: " GRE_NET

    # --- Install Tun2Socks ---
    echo -e "${BLUE}[+] Installing Tun2Socks...${NC}"
    wget -q -O tun2socks.zip "https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-$PAQET_ARCH.zip"
    unzip -o tun2socks.zip > /dev/null
    mv tun2socks-linux-$PAQET_ARCH /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    rm tun2socks.zip

    # --- Config Paqet Client ---
# --- Auto-detect Iran Network Info ---
    GW_IP_IR=$(ip route | grep default | awk '{print $3}' | head -n1)
    ping -c 1 $GW_IP_IR > /dev/null 2>&1
    GW_MAC_IR=$(ip neigh show $GW_IP_IR | awk '{print $5}')
    IFACE_IR=$(ip route | grep default | awk '{print $5}' | head -n1)
    LOCAL_IP_IR=$(curl -s ifconfig.me)

    cat <<EOF > /etc/paqet/config.yaml
role: "client"
log: { level: "error" }
socks5:
  - listen: "127.0.0.1:1080"
network:
  interface: "$IFACE_IR"
  ipv4: { addr: "$LOCAL_IP_IR:0", router_mac: "$GW_MAC_IR" }
server: { addr: "$REMOTE_IP:$REMOTE_PORT" }
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

    # --- Create Network Setup Script ---
    LOCAL_PUB_IP=$(curl -s ifconfig.me)

    cat <<EOF > /usr/local/bin/setup-tunnel.sh
#!/bin/bash
# Auto-Generated Network Script

# 1. Setup GRE
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MIKROTIK_IP local $LOCAL_PUB_IP ttl 255
ip link set gre1 up
ip addr add $GRE_LOCAL dev gre1

# 2. Setup Tun Interface
ip tuntap add dev tun0 mode tun
ip link set tun0 up
ip addr add 10.0.0.1/24 dev tun0

# 3. Routing Logic
ip rule del from $GRE_NET table 100 2>/dev/null
ip route flush table 100

# Prevent Loop
ip route add $GRE_NET dev gre1 table 100
# Internet Traffic
ip route add default dev tun0 table 100

# Apply Policy
ip rule add from $GRE_NET table 100
ip rule add to $GRE_NET lookup main priority 10

# 4. Firewall & MSS
iptables -t nat -F
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
iptables -A FORWARD -i gre1 -o tun0 -j ACCEPT
iptables -A FORWARD -i tun0 -o gre1 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 5. Start Tun2Socks
/usr/local/bin/tun2socks -device tun0 -proxy socks5://127.0.0.1:1080 -udp-timeout 1m
EOF
    chmod +x /usr/local/bin/setup-tunnel.sh

    # --- Systemd Services ---
    cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Client
After=network.target
[Service]
ExecStart=/usr/local/bin/paqet -config /etc/paqet/config.yaml
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/mytunnel.service
[Unit]
Description=GRE and Tun2Socks
After=network.target paqet.service
[Service]
ExecStart=/usr/local/bin/setup-tunnel.sh
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

    # --- Activate ---
    systemctl daemon-reload
    systemctl enable paqet mytunnel

    echo -e "${BLUE}[+] Starting Services...${NC}"
    systemctl restart paqet
    sleep 2
    systemctl restart mytunnel

    echo -e "${GREEN}===========================================${NC}"
    echo -e "${GREEN} INSTALLATION COMPLETE ${NC}"
    echo -e "${GREEN}===========================================${NC}"
    echo -e "Version Installed: $VERSION"
    echo -e "Mode: IRAN CLIENT"
fi