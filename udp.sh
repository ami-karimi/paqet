#!/bin/bash

# ==========================================
#   Ultimate Hybrid Tunnel Setup
#   (UDP2RAW + WireGuard + GRE)
# ==========================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# --- Check Root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}"
   exit 1
fi

# --- Install Dependencies ---
echo -e "${GREEN}[*] Installing Dependencies...${NC}"
apt-get update -y
apt-get install -y wireguard-tools iptables-persistent wget tar qrencode

# --- Download UDP2RAW ---
echo -e "${GREEN}[*] Setting up UDP2RAW...${NC}"
mkdir -p /opt/udp2raw
cd /opt/udp2raw
if [ ! -f udp2raw_bin ]; then
    wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200818.0/udp2raw_binaries.tar.gz
    tar -xzvf udp2raw_binaries.tar.gz > /dev/null
    mv udp2raw_amd64 udp2raw_bin 2>/dev/null || mv udp2raw_x86 udp2raw_bin
    chmod +x udp2raw_bin
fi

# --- Generate WG Keys ---
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/privatekey ]; then
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
fi
PRIV_KEY=$(cat /etc/wireguard/privatekey)
PUB_KEY=$(cat /etc/wireguard/publickey)

# ==========================================
#   USER INPUT & LOGIC
# ==========================================
echo ""
echo "------------------------------------------------"
echo -e "${GREEN}Select Server Role:${NC}"
echo "1) Foreign Server (Kharej) - Endpoint"
echo "2) Iran Server (Iran) - Middleman with GRE"
echo "------------------------------------------------"
read -p "Select [1-2]: " ROLE

# --- Common Configs ---
RAW_PORT=443          # Port visible to Internet (TCP)
WG_PORT=55555         # Internal WG Port
TUN_NET="10.200.0"    # VPN Network

if [ "$ROLE" == "1" ]; then
    # ================= FOREIGN SETUP =================
    echo -e "${GREEN}--- Configuring Foreign Server ---${NC}"
    read -p "Enter UDP2RAW Password: " RAW_PASS
    read -p "Enter Iran Server Public Key: " PEER_PUB

    # 1. UDP2RAW Service (Server)
    cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Server
After=network.target
[Service]
ExecStart=/opt/udp2raw/udp2raw_bin -s -l 0.0.0.0:$RAW_PORT -r 127.0.0.1:$WG_PORT -k $RAW_PASS --raw-mode faketcp -a
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 2. WireGuard Config
    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = $TUN_NET.1/24
ListenPort = $WG_PORT
MTU = 1360
PostUp = iptables -t nat -A POSTROUTING -o $(ip route | grep default | awk '{print $5}') -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $(ip route | grep default | awk '{print $5}') -j MASQUERADE

[Peer]
PublicKey = $PEER_PUB
AllowedIPs = $TUN_NET.2/32
EOF

elif [ "$ROLE" == "2" ]; then
    # ================= IRAN SETUP =================
    echo -e "${GREEN}--- Configuring Iran Server ---${NC}"
    read -p "Enter Foreign Server IP: " REMOTE_IP
    read -p "Enter UDP2RAW Password: " RAW_PASS
    read -p "Enter Foreign Server Public Key: " PEER_PUB

    echo -e "\n${GREEN}--- GRE Settings (Connection to MikroTik) ---${NC}"
    read -p "MikroTik Real IP (Local/Intranet IP): " MK_REAL_IP
    read -p "Iran Server Real IP (Your Local IP): " IRAN_REAL_IP

    GRE_IP_IRAN="172.16.200.1"
    GRE_IP_MK="172.16.200.2"

    # 1. UDP2RAW Service (Client)
    cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Client
After=network.target
[Service]
ExecStart=/opt/udp2raw/udp2raw_bin -c -l 127.0.0.1:$WG_PORT -r $REMOTE_IP:$RAW_PORT -k $RAW_PASS --raw-mode faketcp -a
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 2. WireGuard Config (Connects to Local UDP2RAW)
    cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $PRIV_KEY
Address = $TUN_NET.2/24
MTU = 1360
Table = off

[Peer]
PublicKey = $PEER_PUB
Endpoint = 127.0.0.1:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 10
EOF

    # 3. GRE Setup Script
    cat <<EOF > /usr/local/bin/setup-gre.sh
#!/bin/bash
# Enable Forwarding
sysctl -w net.ipv4.ip_forward=1

# Setup GRE
ip link delete gre1 2>/dev/null
ip tunnel add gre1 mode gre remote $MK_REAL_IP local $IRAN_REAL_IP ttl 255
ip link set gre1 up
ip addr add $GRE_IP_IRAN/30 dev gre1

# Routing & NAT
# Send everything coming from GRE into WireGuard
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
iptables -A FORWARD -i gre1 -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o gre1 -j ACCEPT

# Fix MTU/MSS (CRITICAL for sites to load)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
    chmod +x /usr/local/bin/setup-gre.sh

    # 4. GRE Service
    cat <<EOF > /etc/systemd/system/gre-tunnel.service
[Unit]
Description=GRE Tunnel Setup
After=wg-quick@wg0.service
[Service]
ExecStart=/usr/local/bin/setup-gre.sh
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    systemctl enable gre-tunnel
    systemctl restart gre-tunnel
fi

# --- Start Everything ---
echo -e "${GREEN}[*] Starting Services...${NC}"
systemctl daemon-reload
systemctl enable udp2raw wg-quick@wg0
systemctl restart udp2raw
sleep 2
systemctl restart wg-quick@wg0

# --- Final Info ---
echo ""
echo "========================================================"
if [ "$ROLE" == "1" ]; then
    echo -e "✅ FOREIGN SERVER SETUP COMPLETE"
    echo -e "Your Public Key: ${GREEN}$PUB_KEY${NC}"
    echo -e "UDP2RAW Port:    ${GREEN}$RAW_PORT (TCP)${NC} (Make sure firewall allows this!)"
else
    echo -e "✅ IRAN SERVER SETUP COMPLETE"
    echo -e "Your Public Key: ${GREEN}$PUB_KEY${NC}"
    echo -e "GRE IP (Iran):   ${GREEN}$GRE_IP_IRAN${NC}"
    echo -e "GRE IP (MikroTik): ${GREEN}$GRE_IP_MK${NC}"
    echo "--------------------------------------------------------"
    echo "NOW CONFIGURE MIKROTIK:"
    echo "1. Interface GRE: Remote-Address=$IRAN_REAL_IP"
    echo "2. IP Address:    Address=$GRE_IP_MK/30 Interface=gre1"
    echo "3. IP Route:      Dst=0.0.0.0/0 Gateway=$GRE_IP_IRAN"
    echo "4. IP NAT:        Chain=srcnat Out-Interface=gre1 Action=masquerade"
fi
echo "========================================================"