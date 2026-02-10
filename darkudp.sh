#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

# ==========================================
# EMBEDDED PYTHON SCRIPT (DarkTunnel UDP)
# ==========================================
cat << 'EOF' > /root/darktunnel_udp.py
import socket, os, struct, select, sys, fcntl, subprocess, time

# --- CONFIG ---
KEY = 0x5A          # XOR Key
PORT = 443          # UDP Port
MTU = 1200          # Packet Size
# --------------

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")

def create_tun(dev, ip):
    if not os.path.exists("/dev/net/tun"):
        print("Error: /dev/net/tun missing")
        sys.exit(1)

    tun_fd = os.open("/dev/net/tun", os.O_RDWR)
    ifr = struct.pack("16sH", dev.encode(), 0x0001 | 0x1000)
    fcntl.ioctl(tun_fd, 0x400454ca, ifr)

    subprocess.run(f"ip addr add {ip}/24 dev {dev}", shell=True)
    subprocess.run(f"ip link set dev {dev} mtu {MTU} up", shell=True)
    return tun_fd

def xor(data):
    return bytes([b ^ KEY for b in data])

def run_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', PORT))
    log(f"UDP Server listening on {PORT}...")

    tun = create_tun("tun0", "10.10.10.1")
    client_addr = None
    fds = [tun, sock]

    while True:
        try:
            r, _, _ = select.select(fds, [], [], 10)
            for fd in r:
                if fd == tun:
                    pkt = os.read(tun, MTU)
                    if client_addr: sock.sendto(xor(pkt), client_addr)
                elif fd == sock:
                    data, addr = sock.recvfrom(MTU + 100)
                    client_addr = addr
                    if len(data) > 0: os.write(tun, xor(data))
        except Exception as e:
            log(f"Error: {e}")

def run_client(ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (ip, PORT)
    log(f"Targeting {ip}:{PORT} (UDP)...")

    tun = create_tun("tun0", "10.10.10.2")
    sock.sendto(xor(b"PING"), addr) # Punch NAT

    fds = [tun, sock]
    last_ping = time.time()

    while True:
        try:
            if time.time() - last_ping > 5:
                sock.sendto(xor(b"PING"), addr)
                last_ping = time.time()

            r, _, _ = select.select(fds, [], [], 5)
            for fd in r:
                if fd == tun:
                    pkt = os.read(tun, MTU)
                    sock.sendto(xor(pkt), addr)
                elif fd == sock:
                    data, _ = sock.recvfrom(MTU + 100)
                    decrypted = xor(data)
                    if decrypted != b"PING": os.write(tun, decrypted)
        except Exception as e:
            log(f"Retry... {e}")
            time.sleep(2)

if __name__ == "__main__":
    if sys.argv[1] == "server": run_server()
    else: run_client(sys.argv[2])
EOF
# ==========================================


install_service() {
    TYPE=$1
    REMOTE_IP=$2

    echo -e "${YELLOW}Stopping old services...${NC}"
    systemctl stop darktunnel_udp 2>/dev/null
    systemctl disable darktunnel_udp 2>/dev/null
    rm /etc/systemd/system/darktunnel_udp.service 2>/dev/null

    # Cleanup Network
    ip link delete tun0 2>/dev/null
    killall python3 2>/dev/null

    # Firewall Rules (Critical for UDP)
    echo -e "${YELLOW}Configuring Firewall (UDP)...${NC}"
    if [ "$TYPE" == "server" ]; then
        iptables -I INPUT -p udp --dport 443 -j ACCEPT
        # Enable Forwarding
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    fi

    echo -e "${YELLOW}Creating Service...${NC}"

    if [ "$TYPE" == "server" ]; then
        CMD="/usr/bin/python3 /root/darktunnel_udp.py server"
    else
        CMD="/usr/bin/python3 /root/darktunnel_udp.py client $REMOTE_IP"
    fi

    cat << EoS > /etc/systemd/system/darktunnel_udp.service
[Unit]
Description=DarkTunnel UDP
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EoS

    systemctl daemon-reload
    systemctl enable darktunnel_udp
    systemctl start darktunnel_udp

    echo -e "${GREEN}Installation Complete!${NC}"

    if [ "$TYPE" == "client" ]; then
        echo -e "Wait 5 seconds, then try: ${YELLOW}ping 10.10.10.1${NC}"
    fi
}

# MENU
clear
echo -e "${GREEN}DarkTunnel UDP Installer (Anti-DPI)${NC}"
echo "-----------------------------------"
echo "1) Install Kharej (Server)"
echo "2) Install Iran (Client)"
echo "3) Uninstall"
echo "4) Exit"
echo "-----------------------------------"
read -p "Select: " opt

case $opt in
    1)
        install_service "server" ""
        ;;
    2)
        read -p "Enter Kharej IP: " ip
        install_service "client" "$ip"
        ;;
    3)
        systemctl stop darktunnel_udp
        systemctl disable darktunnel_udp
        rm /etc/systemd/system/darktunnel_udp.service
        rm /root/darktunnel_udp.py
        echo "Removed."
        ;;
    4) exit ;;
    *) echo "Invalid" ;;
esac