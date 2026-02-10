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
# EMBEDDED PYTHON SCRIPT (UDP Stealth)
# ==========================================
cat << 'EOF' > /root/darktunnel_stealth.py
import socket, os, struct, select, sys, fcntl, subprocess, time, random

# --- CONFIG ---
KEY = 0x5A          # XOR Key
PORT = 24080        # Custom UDP Port
MTU = 1200          # MTU Size
# --------------

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")

def create_tun(dev, ip):
    if not os.path.exists("/dev/net/tun"):
        print("Error: /dev/net/tun missing")
        sys.exit(1)

    try:
        tun_fd = os.open("/dev/net/tun", os.O_RDWR)
        ifr = struct.pack("16sH", dev.encode(), 0x0001 | 0x1000)
        fcntl.ioctl(tun_fd, 0x400454ca, ifr)

        subprocess.run(f"ip addr add {ip}/24 dev {dev}", shell=True)
        subprocess.run(f"ip link set dev {dev} mtu {MTU} up", shell=True)
        return tun_fd
    except Exception as e:
        print(f"TUN Error: {e}")
        sys.exit(1)

def xor(data):
    return bytes([b ^ KEY for b in data])

def wrap_packet(data):
    # Add random noise to change packet size (Anti-QoS)
    noise_len = random.randint(10, 50)
    noise = os.urandom(noise_len)
    length_header = struct.pack("!H", len(data))
    return xor(length_header + data + noise)

def unwrap_packet(raw_data):
    try:
        decrypted = xor(raw_data)
        real_len = struct.unpack("!H", decrypted[:2])[0]
        return decrypted[2:2+real_len]
    except:
        return None

def run_server():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('0.0.0.0', PORT))
    log(f"Stealth UDP Server listening on {PORT}...")

    tun = create_tun("tun0", "10.10.10.1")
    client_addr = None
    fds = [tun, sock]

    while True:
        try:
            r, _, _ = select.select(fds, [], [], 10)
            for fd in r:
                if fd == tun:
                    pkt = os.read(tun, MTU)
                    if client_addr: sock.sendto(wrap_packet(pkt), client_addr)
                elif fd == sock:
                    data, addr = sock.recvfrom(2048)
                    client_addr = addr
                    payload = unwrap_packet(data)
                    if payload and len(payload) > 0: os.write(tun, payload)
        except Exception as e:
            log(f"Error: {e}")

def run_client(ip):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    addr = (ip, PORT)
    log(f"Targeting {ip}:{PORT} with Random Padding...")

    tun = create_tun("tun0", "10.10.10.2")
    sock.sendto(wrap_packet(b"PING"), addr)

    fds = [tun, sock]
    last_ping = time.time()

    while True:
        try:
            if time.time() - last_ping > 2:
                sock.sendto(wrap_packet(b"PING"), addr)
                last_ping = time.time()

            r, _, _ = select.select(fds, [], [], 2)
            for fd in r:
                if fd == tun:
                    pkt = os.read(tun, MTU)
                    sock.sendto(wrap_packet(pkt), addr)
                elif fd == sock:
                    data, _ = sock.recvfrom(2048)
                    payload = unwrap_packet(data)
                    if payload and payload != b"PING": os.write(tun, payload)
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
    systemctl stop darktunnel_stealth 2>/dev/null
    systemctl disable darktunnel_stealth 2>/dev/null
    rm /etc/systemd/system/darktunnel_stealth.service 2>/dev/null

    # Cleanup Network
    ip link delete tun0 2>/dev/null
    killall python3 2>/dev/null

    # Firewall Rules (Crucial for UDP 24080)
    echo -e "${YELLOW}Configuring Firewall...${NC}"
    if [ "$TYPE" == "server" ]; then
        iptables -I INPUT -p udp --dport 24080 -j ACCEPT
        echo 1 > /proc/sys/net/ipv4/ip_forward
        iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    elif [ "$TYPE" == "client" ]; then
        # Anti-Loop: Force connection to server via default gateway
        GW=$(ip route show default | awk '/default/ {print $3}')
        echo -e "Adding static route to $REMOTE_IP via $GW"
        ip route add $REMOTE_IP via $GW 2>/dev/null
    fi

    echo -e "${YELLOW}Creating Service...${NC}"

    if [ "$TYPE" == "server" ]; then
        CMD="/usr/bin/python3 /root/darktunnel_stealth.py server"
    else
        CMD="/usr/bin/python3 /root/darktunnel_stealth.py client $REMOTE_IP"
    fi

    cat << EoS > /etc/systemd/system/darktunnel_stealth.service
[Unit]
Description=DarkTunnel Stealth UDP
After=network.target

[Service]
ExecStart=$CMD
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EoS

    systemctl daemon-reload
    systemctl enable darktunnel_stealth
    systemctl start darktunnel_stealth

    echo -e "${GREEN}Installation Complete!${NC}"

    if [ "$TYPE" == "client" ]; then
        echo -e "Wait a moment, then ping: ${YELLOW}ping 10.10.10.1${NC}"
    fi
}

# MENU
clear
echo -e "${GREEN}DarkTunnel Stealth UDP Installer${NC}"
echo -e "${YELLOW}(Anti-QoS / Random Packet Size)${NC}"
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
        systemctl stop darktunnel_stealth
        systemctl disable darktunnel_stealth
        rm /etc/systemd/system/darktunnel_stealth.service
        rm /root/darktunnel_stealth.py
        echo "Removed."
        ;;
    4) exit ;;
    *) echo "Invalid" ;;
esac