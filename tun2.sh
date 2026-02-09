#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo ./install.sh)${NC}"
  exit
fi

INSTALL_DIR="/opt/stealth_tunnel"
SERVICE_FILE="/etc/systemd/system/stealth-tunnel.service"

echo -e "${GREEN}=== Stealth Raw IP Tunnel Installer ===${NC}"
echo "1) Server (Foreign/Outside)"
echo "2) Client (Iran/Local)"
echo "3) Uninstall / Remove"
read -p "Select option [1-3]: " choice

if [ "$choice" == "3" ]; then
    echo -e "${YELLOW}Stopping service...${NC}"
    systemctl stop stealth-tunnel
    systemctl disable stealth-tunnel
    rm $SERVICE_FILE
    rm -rf $INSTALL_DIR
    systemctl daemon-reload
    echo -e "${GREEN}Uninstalled successfully.${NC}"
    exit 0
fi

read -p "Enter Remote Server IP (The Public IP of the OTHER side): " REMOTE_IP

if [ -z "$REMOTE_IP" ]; then
    echo -e "${RED}Error: Remote IP is required.${NC}"
    exit 1
fi

# Configuration based on choice
if [ "$choice" == "1" ]; then
    # Server Mode
    LOCAL_TUN="10.0.0.1"
    PEER_TUN="10.0.0.2"
    echo -e "${GREEN}Configuring as SERVER...${NC}"
elif [ "$choice" == "2" ]; then
    # Client Mode
    LOCAL_TUN="10.0.0.2"
    PEER_TUN="10.0.0.1"
    echo -e "${GREEN}Configuring as CLIENT...${NC}"
else
    echo -e "${RED}Invalid option.${NC}"
    exit 1
fi

# 1. Create Directory and Python Script
mkdir -p $INSTALL_DIR

cat << 'EOF' > $INSTALL_DIR/tunnel.py
import socket
import os
import struct
import select
import sys
import fcntl
import itertools
import time

# CONFIGURATION
XOR_KEY = b'MySecretKey_NoDPI_2024_Goes_Brrr'
CUSTOM_PROTO = 253
TUN_NAME = 'tun_stealth'
MTU = 1400

# Linux constants
TUNSETIFF = 0x400454ca
IFF_TUN   = 0x0001
IFF_NO_PI = 0x1000

def create_tun_interface(dev_name):
    tun_fd = os.open("/dev/net/tun", os.O_RDWR)
    ifr = struct.pack("16sH", dev_name.encode("utf-8"), IFF_TUN | IFF_NO_PI)
    fcntl.ioctl(tun_fd, TUNSETIFF, ifr)
    return tun_fd

def set_ip(dev_name, local_ip, peer_ip):
    os.system(f"ip link set dev {dev_name} mtu {MTU}")
    os.system(f"ip addr add {local_ip} peer {peer_ip} dev {dev_name}")
    os.system(f"ip link set {dev_name} up")
    print(f"Interface {dev_name} UP. Local: {local_ip} -> Peer: {peer_ip}")

def xor_data(data, key):
    return bytes(a ^ b for a, b in zip(data, itertools.cycle(key)))

def main(remote_ip, tun_local, tun_peer):
    try:
        tun_fd = create_tun_interface(TUN_NAME)
        set_ip(TUN_NAME, tun_local, tun_peer)
    except Exception as e:
        print(f"Error creating TUN: {e}")
        return

    try:
        raw_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, CUSTOM_PROTO)
    except Exception as e:
        print(f"Error creating Raw Socket: {e}")
        return

    print(f"Tunnel started. Sending to {remote_ip}")
    inputs = [tun_fd, raw_sock]

    while True:
        try:
            readable, _, _ = select.select(inputs, [], [])
            for source in readable:
                if source is tun_fd:
                    packet = os.read(tun_fd, MTU + 100)
                    if packet:
                        obfuscated = xor_data(packet, XOR_KEY)
                        raw_sock.sendto(obfuscated, (remote_ip, 0))
                elif source is raw_sock:
                    raw_data, addr = raw_sock.recvfrom(MTU + 100)
                    if len(raw_data) > 20:
                        payload = raw_data[(raw_data[0] & 0x0F) * 4:]
                        if payload:
                            os.write(tun_fd, xor_data(payload, XOR_KEY))
        except Exception:
            pass

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
EOF

# 2. Configure Firewall (Allow Protocol 253)
echo -e "${YELLOW}Configuring Firewall...${NC}"
iptables -C INPUT -p 253 -j ACCEPT 2>/dev/null || iptables -I INPUT -p 253 -j ACCEPT
iptables -C OUTPUT -p 253 -j ACCEPT 2>/dev/null || iptables -I OUTPUT -p 253 -j ACCEPT

# Save iptables (Basic attempt, might vary by distro)
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
elif command -v service &> /dev/null; then
    service iptables save 2>/dev/null
fi

# 3. Create Systemd Service
echo -e "${YELLOW}Creating Systemd Service...${NC}"
cat << EOF > $SERVICE_FILE
[Unit]
Description=Stealth Raw IP Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/tunnel.py $REMOTE_IP $LOCAL_TUN $PEER_TUN
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 4. Enable and Start
systemctl daemon-reload
systemctl enable stealth-tunnel
systemctl start stealth-tunnel

echo -e "${GREEN}✅ Installation Complete!${NC}"
echo -e "Status check: ${YELLOW}systemctl status stealth-tunnel${NC}"

if [ "$choice" == "2" ]; then
    echo -e "\n${YELLOW}=== IMPORTANT: ROUTING COMMANDS ===${NC}"
    echo "Run these commands manually to route traffic:"

    # Try to find default gateway
    DEFAULT_GW=$(ip route | grep default | awk '{print $3}' | head -n 1)

    echo -e "1. Keep connection to server alive:\n   ${GREEN}ip route add $REMOTE_IP via $DEFAULT_GW${NC}"
    echo -e "2. Route everything else through tunnel:\n   ${GREEN}ip route add default via 10.0.0.1 dev tun_stealth metric 1${NC}"
fi