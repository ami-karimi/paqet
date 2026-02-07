#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 1. CLEANUP & INSTALL ---
echo -e "${YELLOW}[*] Cleaning up mess...${NC}"
systemctl stop awg-quick@awg0 2>/dev/null
systemctl disable awg-quick@awg0 2>/dev/null
ip link delete awg0 2>/dev/null
ip link delete gre1 2>/dev/null
apt-get remove --purge -y amneziawg amneziawg-tools wireguard-tools 2>/dev/null
apt-get autoremove -y

echo -e "${YELLOW}[*] Installing fresh AmneziaWG...${NC}"
add-apt-repository ppa:amnezia/ppa -y > /dev/null 2>&1
apt-get update > /dev/null
apt-get install -y linux-headers-$(uname -r) amneziawg amneziawg-tools iptables-persistent

# --- 2. KEY GENERATION ---
mkdir -p /etc/amnezia
# Generate keys if not exist
if [ ! -f /etc/amnezia/privatekey ]; then
    awg genkey | tee /etc/amnezia/privatekey | awg pubkey > /etc/amnezia/publickey
fi
PRIV_KEY=$(cat /etc/amnezia/privatekey)
PUB_KEY=$(cat /etc/amnezia/publickey)

# --- 3. AUTO DETECT IP ---
DEF_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
LOCAL_IP=$(ip -4 addr show $DEF_IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

echo -e "${GREEN}=======================================${NC}"
echo -e "YOUR IP: $LOCAL_IP"
echo -e "YOUR PUBLIC KEY: ${YELLOW}$PUB_KEY${NC}"
echo -e "${GREEN}=======================================${NC}"

# --- 4. CONFIGURATION ---
echo "Select Role:"
echo "1) Foreign Server (Server)"
echo "2) Iran Server (Bridge)"
read -p "Choice: " ROLE

cat <<EOF > /usr/local/bin/start-tunnel.sh
#!/bin/bash
# Clear old interface
ip link delete awg0 2>/dev/null

# Create Interface directly
ip link add dev awg0 type amneziawg
ip link set mtu 1420 up dev awg0
EOF

if [ "$ROLE" == "1" ]; then
    # --- FOREIGN ---
    read -p "Enter Iran Public Key: " PEER_PUB

    # Append commands to script
    cat <<EOF >> /usr/local/bin/start-tunnel.sh
ip address add 10.0.0.1/24 dev awg0
awg set awg0 private-key /etc/amnezia/privatekey listen-port 444 \
jc 40 jmin 50 jmax 1000 s1 0 s2 0 h1 0x01020304 h2 0x05060708 h3 0x090a0b0c h4 0x0d0e0f10 \
peer "$PEER_PUB" allowed-ips 10.0.0.2/32,172.16.1.0/30
EOF
    echo -e "${GREEN}Foreign Setup Prepared.${NC}"

else
    # --- IRAN ---
    read -p "Enter Foreign IP: " REM_IP
    read -p "Enter Foreign Public Key: " REM_PUB
    read -p "MikroTik IP (Tunnel Destination): " MK_IP
    read -p "GRE Local IP (e.g. 172.16.1.1/30): " GRE_IP
    read -p "GRE Network (e.g. 172.16.1.0/30): " GRE_NET

    cat <<EOF >> /usr/local/bin/start-tunnel.sh
ip address add 10.0.0.2/24 dev awg0
awg set awg0 private-key /etc/amnezia/privatekey \
jc 40 jmin 50 jmax 1000 s1 0 s2 0 h1 0x01020304 h2 0x05060708 h3 0x090a0b0c h4 0x0d0e0f10 \
peer "$REM_PUB" endpoint $REM_IP:444 allowed-ips 0.0.0.0/0 persistent-keepalive 25

# GRE Setup
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_IP local $LOCAL_IP ttl 255
ip link set gre1 up
ip addr add $GRE_IP dev gre1

# Routing
ip rule del from $GRE_NET table 100 2>/dev/null
ip route flush table 100
ip route add $GRE_NET dev gre1 table 100
ip route add default dev awg0 table 100
ip rule add from $GRE_NET table 100

# NAT
iptables -t nat -A POSTROUTING -o awg0 -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
    echo -e "${GREEN}Iran Setup Prepared.${NC}"
fi

chmod +x /usr/local/bin/start-tunnel.sh

# --- 5. CREATE SYSTEMD SERVICE ---
cat <<EOF > /etc/systemd/system/awg-manual.service
[Unit]
Description=AmneziaWG Manual Setup
After=network.target

[Service]
ExecStart=/usr/local/bin/start-tunnel.sh
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- 6. START ---
echo -e "${BLUE}Starting Service...${NC}"
systemctl daemon-reload
systemctl enable awg-manual
systemctl restart awg-manual

# --- 7. VERIFY ---
sleep 2
echo -e "${YELLOW}--- Tunnel Status ---${NC}"
awg show
echo -e "${YELLOW}--- IP Address ---${NC}"
ip addr show awg0