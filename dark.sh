#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit
fi

# ==========================================
# EMBEDDED PYTHON SCRIPT (DarkTunnel)
# ==========================================
cat << 'EOF' > /root/darktunnel.py
import socket, ssl, os, struct, select, sys, fcntl, subprocess, time

PASSWORD = b"Amir1404_SECURE_KEY"
PORT = 443
MTU = 1200
CERT_FILE = "/root/server.crt"
KEY_FILE  = "/root/server.key"

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")

def generate_cert():
    if not os.path.exists(CERT_FILE) or not os.path.exists(KEY_FILE):
        subprocess.run(f'openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -keyout {KEY_FILE} -out {CERT_FILE} -subj "/CN=www.microsoft.com"', shell=True, stderr=subprocess.DEVNULL)

def create_tun(dev, ip):
    if not os.path.exists("/dev/net/tun"):
        print("Error: TUN device not found.")
        sys.exit(1)
    tun_fd = os.open("/dev/net/tun", os.O_RDWR)
    ifr = struct.pack("16sH", dev.encode(), 0x0001 | 0x1000)
    fcntl.ioctl(tun_fd, 0x400454ca, ifr)
    subprocess.run(f"ip addr add {ip}/24 dev {dev}", shell=True)
    subprocess.run(f"ip link set dev {dev} mtu {MTU} up", shell=True)
    return tun_fd

def get_context(mode):
    if mode == 'server':
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        return ctx
    else:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx

def loop(tun, sock):
    fds = [tun, sock]
    while True:
        try:
            r, _, _ = select.select(fds, [], [], 10)
            if not r: continue
            for fd in r:
                if fd == tun:
                    data = os.read(tun, MTU)
                    if not data: raise Exception("TUN read error")
                    sock.sendall(struct.pack("!H", len(data)) + data)
                elif fd == sock:
                    head = sock.recv(2)
                    if not head: raise Exception("Socket closed")
                    l = struct.unpack("!H", head)[0]
                    data = b""
                    while len(data) < l:
                        packet = sock.recv(l - len(data))
                        if not packet: raise Exception("Incomplete packet")
                        data += packet
                    os.write(tun, data)
        except Exception as e:
            log(f"Link broken: {e}")
            break

def run_server():
    generate_cert()
    while True:
        try:
            srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind(('0.0.0.0', PORT))
            srv.listen(1)
            log(f"Listening on {PORT}...")
            conn, addr = srv.accept()
            log(f"Connected: {addr}")
            try:
                ctx = get_context('server')
                ssock = ctx.wrap_socket(conn, server_side=True)
                if ssock.recv(len(PASSWORD)) != PASSWORD:
                    ssock.close()
                    continue
                tun = create_tun("tun0", "10.10.10.1")
                loop(tun, ssock)
            except Exception as e:
                log(e)
            finally:
                try: os.close(tun)
                except: pass
                srv.close()
        except:
            time.sleep(2)

def run_client(ip):
    while True:
        try:
            log(f"Connecting to {ip}...")
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((ip, PORT))
            sock.settimeout(None)
            ctx = get_context('client')
            ssock = ctx.wrap_socket(sock, server_side=False)
            ssock.sendall(PASSWORD)
            tun = create_tun("tun0", "10.10.10.2")
            log("Tunnel UP!")
            loop(tun, ssock)
        except Exception as e:
            log(f"Retry in 3s... ({e})")
            time.sleep(3)
        finally:
            try: os.close(tun)
            except: pass

if __name__ == "__main__":
    if sys.argv[1] == "server": run_server()
    else: run_client(sys.argv[2])
EOF
# ==========================================


# Function to Install Service
install_service() {
    TYPE=$1
    REMOTE_IP=$2

    echo -e "${YELLOW}Cleaning up old services...${NC}"
    systemctl stop darktunnel 2>/dev/null
    systemctl disable darktunnel 2>/dev/null
    rm /etc/systemd/system/darktunnel.service 2>/dev/null
    
    # Cleanup Network
    ip link delete tun0 2>/dev/null
    killall python3 2>/dev/null

    echo -e "${YELLOW}Creating Systemd Service...${NC}"
    
    if [ "$TYPE" == "server" ]; then
        CMD="/usr/bin/python3 /root/darktunnel.py server"
    else
        CMD="/usr/bin/python3 /root/darktunnel.py client $REMOTE_IP"
    fi

    cat << EoS > /etc/systemd/system/darktunnel.service
[Unit]
Description=DarkTunnel Service
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
    systemctl enable darktunnel
    systemctl start darktunnel

    echo -e "${GREEN}Installation Complete!${NC}"
    echo -e "Check status with: ${YELLOW}systemctl status darktunnel${NC}"
    
    if [ "$TYPE" == "client" ]; then
        echo -e "Test connection with: ${YELLOW}ping 10.10.10.1${NC}"
    fi
}


# MENU
clear
echo -e "${GREEN}DarkTunnel Auto-Installer${NC}"
echo "-------------------------"
echo "1) Install Kharej (Server)"
echo "2) Install Iran (Client)"
echo "3) Uninstall & Remove"
echo "4) Exit"
echo "-------------------------"
read -p "Select option: " option

case $option in
    1)
        echo -e "${GREEN}Installing Server (Kharej)...${NC}"
        # Install dependencies
        apt update && apt install python3 openssl -y
        install_service "server" ""
        ;;
    2)
        read -p "Enter Kharej IP: " kharej_ip
        echo -e "${GREEN}Installing Client (Iran)...${NC}"
        install_service "client" "$kharej_ip"
        ;;
    3)
        echo -e "${RED}Uninstalling...${NC}"
        systemctl stop darktunnel
        systemctl disable darktunnel
        rm /etc/systemd/system/darktunnel.service
        rm /root/darktunnel.py
        systemctl daemon-reload
        echo "Removed."
        ;;
    4)
        exit
        ;;
    *)
        echo "Invalid option"
        ;;
esac