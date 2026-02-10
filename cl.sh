#!/bin/bash

# --- VARIABLES ---
GOST_PATH="/usr/local/bin/gost"
SCANNER_DIR="/root/cf-scanner"
SCANNER_PATH="$SCANNER_DIR/CloudflareSpeedTest"
RUNNER_SCRIPT="/usr/local/bin/run_gost_smart.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Please run as root${NC}"
   exit 1
fi

# 1. Install Tools
install_tools() {
    apt-get update -y > /dev/null 2>&1
    apt-get install wget tar awk -y > /dev/null 2>&1

    # Install GOST
    if [ ! -f "$GOST_PATH" ]; then
        echo -e "${YELLOW}Downloading GOST...${NC}"
        wget -N --no-check-certificate https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
        gunzip -f gost-linux-amd64-2.11.5.gz
        mv gost-linux-amd64-2.11.5 $GOST_PATH
        chmod +x $GOST_PATH
    fi

    # Install Scanner
    if [ ! -d "$SCANNER_DIR" ]; then
        echo -e "${YELLOW}Downloading Cloudflare Scanner...${NC}"
        mkdir -p $SCANNER_DIR
        cd $SCANNER_DIR
        wget -N --no-check-certificate https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/CloudflareSpeedTest_linux_amd64.tar.gz
        tar -zxf CloudflareSpeedTest_linux_amd64.tar.gz
        chmod +x CloudflareSpeedTest
    fi
}

# 2. Create the Smart Runner Script
create_runner() {
    echo -e "${YELLOW}Creating Smart Runner Script...${NC}"

    cat > $RUNNER_SCRIPT <<EOF
#!/bin/bash
cd $SCANNER_DIR

# Run scanner (Fast mode: 5 pings, download 2 IPs to test speed)
echo "Scanning for best Cloudflare IP..."
./CloudflareSpeedTest -t 5 -dn 2 -dt 5 -p 10 -o ip.csv

# Extract the best IP (First line is header, second is best IP)
BEST_IP=\$(sed -n '2p' ip.csv | cut -d',' -f1)

if [[ -z "\$BEST_IP" ]]; then
    echo "Scan failed, using fallback IP."
    BEST_IP="104.16.123.123" # Fallback
else
    echo "Found Best IP: \$BEST_IP"
fi

# Run GOST with the found IP
# Using 'exec' to replace the shell process with GOST
exec $GOST_PATH -L=tcp://:${LOCAL_PORT}/${DEST_IP}:${DEST_PORT} -F="wss://${USER}:${PASS}@${DOMAIN}:443?path=/ws&ip=\$BEST_IP"
EOF

    chmod +x $RUNNER_SCRIPT
}

# 3. Create Systemd Service
create_service() {
    echo -e "${YELLOW}Creating Systemd Service...${NC}"
    cat > /etc/systemd/system/gost-smart.service <<EOF
[Unit]
Description=GOST Smart Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=$RUNNER_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost-smart
}

# --- MAIN SETUP ---
setup_iran_smart() {
    install_tools

    echo -e "${GREEN}--- Setup Iran Server (Auto-IP) ---${NC}"
    read -p "Enter Your Domain (e.g. sub.domain.com): " DOMAIN
    read -p "Enter Username (from Kharej): " USER
    read -p "Enter Password (from Kharej): " PASS
    read -p "Enter Local Port to Open (e.g. 6060): " LOCAL_PORT
    read -p "Enter Dest IP (e.g. 127.0.0.1): " DEST_IP
    read -p "Enter Dest Port: " DEST_PORT

    # Export variables to be used inside the runner script creation
    export DOMAIN USER PASS LOCAL_PORT DEST_IP DEST_PORT

    # We need to hardcode these into the runner script or pass them as args
    # For simplicity, rewriting the runner with variables baked in:

    cat > $RUNNER_SCRIPT <<EOF
#!/bin/bash
cd $SCANNER_DIR

echo "Scanning for clean IP..."
# -p 5: ping count, -dn 2: download count, -tl 300: max latency 300ms
./CloudflareSpeedTest -p 5 -dn 2 -tl 300 -tll 20 -o ip.csv

BEST_IP=\$(sed -n '2p' ip.csv | cut -d',' -f1)

if [[ -z "\$BEST_IP" ]]; then
    echo "Scan failed! Using fallback."
    BEST_IP="104.17.152.41"
fi

echo "Connecting via: \$BEST_IP"
exec $GOST_PATH -L=tcp://:${LOCAL_PORT}/${DEST_IP}:${DEST_PORT} -F="wss://${USER}:${PASS}@${DOMAIN}:443?path=/ws&ip=\$BEST_IP"
EOF
    chmod +x $RUNNER_SCRIPT

    create_service
    systemctl restart gost-smart

    echo -e "${GREEN}Done! The service will auto-scan on every restart.${NC}"
    echo -e "To get a new IP manually: ${YELLOW}systemctl restart gost-smart${NC}"
}

setup_iran_smart