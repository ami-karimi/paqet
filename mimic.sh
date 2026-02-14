#!/bin/bash
# ==========================================
# Mimic eBPF Tunnel Auto-Installer
# ==========================================

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "${GREEN}=== Mimic Tunnel Setup Script ===${RESET}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root! (sudo -i)${RESET}"
  exit 1
fi

# 1. تشخیص سیستم‌عامل و معماری
OS_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)

echo -e "${YELLOW}Detected OS: $OS_CODENAME ($ARCH)${RESET}"

# 2. نصب پیش‌نیازها
echo "Installing dependencies..."
apt-get update -y > /dev/null
apt-get install -y curl wget jq dkms linux-headers-$(uname -r) lsb-release > /dev/null

# 3. دریافت لینک دانلود آخرین نسخه از گیت‌هاب
API_URL="https://api.github.com/repos/hack3ric/mimic/releases/latest"
echo "Fetching latest mimic release info..."

MIMIC_DEB=$(curl -s $API_URL | jq -r ".assets[] | .browser_download_url" | grep "${OS_CODENAME}_mimic_" | grep "${ARCH}.deb$")
DKMS_DEB=$(curl -s $API_URL | jq -r ".assets[] | .browser_download_url" | grep "${OS_CODENAME}_mimic-dkms" | grep "${ARCH}.deb$")

if [ -z "$MIMIC_DEB" ] || [ -z "$DKMS_DEB" ]; then
    echo -e "${RED}Error: Pre-built packages for $OS_CODENAME ($ARCH) not found in GitHub releases.${RESET}"
    echo "Supported OS versions usually are: bookworm (Debian 12), trixie (Debian 13), noble (Ubuntu 24.04)."
    echo "Please use a supported OS to avoid manual compilation."
    exit 1
fi

echo "Downloading Mimic packages..."
wget -qO mimic.deb "$MIMIC_DEB"
wget -qO mimic-dkms.deb "$DKMS_DEB"

echo "Installing Mimic packages..."
dpkg -i mimic-dkms.deb mimic.deb
apt-get install -f -y

# 4. منوی تنظیمات
echo ""
echo -e "${YELLOW}--- Configuration ---${RESET}"
echo "1) Server (Kharej)"
echo "2) Client (Iran)"
read -p "Select role [1 or 2]: " ROLE

# پیدا کردن خودکار کارت شبکه
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
read -p "Network Interface [$DEFAULT_IFACE]: " IFACE
IFACE=${IFACE:-$DEFAULT_IFACE}

if [ "$ROLE" == "1" ]; then
    read -p "TCP Port to listen on (e.g., 443): " TCP_PORT
    read -p "Local UDP Port of your Tunnel (e.g., 51820): " UDP_PORT

    EXEC_CMD="/usr/bin/mimic --server --listen-tcp 0.0.0.0:$TCP_PORT --target-udp 127.0.0.1:$UDP_PORT --interface $IFACE"
    SERVICE_NAME="mimic-server"

elif [ "$ROLE" == "2" ]; then
    read -p "Remote Kharej IP: " KHAREJ_IP
    read -p "Remote Kharej TCP Port (e.g., 443): " TCP_PORT
    read -p "Local UDP Port to listen on (e.g., 51820): " UDP_PORT

    EXEC_CMD="/usr/bin/mimic --client --listen-udp 127.0.0.1:$UDP_PORT --target-tcp $KHAREJ_IP:$TCP_PORT --interface $IFACE"
    SERVICE_NAME="mimic-client"
else
    echo -e "${RED}Invalid option! Script aborted.${RESET}"
    exit 1
fi

# 5. ساخت و اجرای سرویس
echo "Creating systemd service: ${SERVICE_NAME}.service..."
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Mimic eBPF Obfuscator ($SERVICE_NAME)
After=network.target

[Service]
Type=simple
User=root
ExecStart=$EXEC_CMD
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo ""
echo -e "${GREEN}=====================================${RESET}"
echo -e "${GREEN}Installation & Configuration Complete!${RESET}"
echo -e "${GREEN}=====================================${RESET}"
echo "Service status: systemctl status ${SERVICE_NAME}.service"
echo "Live logs     : journalctl -fu ${SERVICE_NAME}.service"
echo -e "${YELLOW}Important: Remember to lower your Tunnel MTU by 12 bytes! (e.g., 1408 instead of 1420)${RESET}"