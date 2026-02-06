#!/bin/bash

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً با دسترسی root اجرا کنید.${NC}"
  exit
fi

echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#   Paqet Auto-Installer (Smart Architecture)   #${NC}"
echo -e "${BLUE}#################################################${NC}"

# ---------------------------------------------
# ۱. تشخیص معماری پردازنده (Fixing 203/EXEC)
# ---------------------------------------------
ARCH=$(uname -m)
echo -e "${YELLOW}[INFO] معماری پردازنده شما: $ARCH${NC}"

if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo -e "${RED}[ERROR] معماری $ARCH پشتیبانی نمی‌شود!${NC}"
    exit 1
fi

# ---------------------------------------------
# ۲. نصب پیش‌نیازها
# ---------------------------------------------
echo -e "${GREEN}[+] نصب پیش‌نیازها...${NC}"
apt-get update -qq
apt-get install -y libpcap-dev iptables iptables-persistent net-tools curl wget file -qq

# ---------------------------------------------
# ۳. دانلود هوشمند Paqet
# ---------------------------------------------
echo -e "${GREEN}[+] در حال دانلود نسخه مخصوص $PAQET_ARCH...${NC}"

# توقف سرویس اگر قبلاً نصب شده
systemctl stop paqet 2>/dev/null

DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.13/paqet_linux_${PAQET_ARCH}"
TARGET_BIN="/usr/local/bin/paqet"

rm -f $TARGET_BIN
wget -q -O $TARGET_BIN "$DOWNLOAD_URL"

# بررسی صحت فایل دانلود شده
if file $TARGET_BIN | grep -q "executable"; then
    echo -e "${GREEN}✓ دانلود موفقیت‌آمیز بود.${NC}"
    chmod +x $TARGET_BIN
else
    echo -e "${RED}[FATAL] دانلود فایل خراب بود! احتمالاً لینک تغییر کرده یا شبکه مشکل دارد.${NC}"
    echo -e "${RED}محتوای فایل دانلود شده:${NC}"
    head -n 5 $TARGET_BIN
    exit 1
fi

# ---------------------------------------------
# ۴. دریافت اطلاعات شبکه
# ---------------------------------------------
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
ping -c 1 $GATEWAY_IP > /dev/null 2>&1
GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}')
SERVER_IP=$(curl -s ifconfig.me)

# ---------------------------------------------
# ۵. تنظیمات کاربر
# ---------------------------------------------
echo "-------------------------------------------------"
echo -e "${BLUE}نقش سرور را انتخاب کنید:${NC}"
echo "1) سرور خارج (Server Mode)"
echo "2) سرور ایران (Client Mode)"
read -p "> " ROLE_CHOICE

read -p "پورت Paqet (پیش‌فرض 9999): " PAQET_PORT
PAQET_PORT=${PAQET_PORT:-9999}

read -p "رمز عبور تانل (حتماً در هر دو سرور یکی باشد): " PAQET_KEY
if [ -z "$PAQET_KEY" ]; then echo "رمز الزامی است"; exit 1; fi

# ---------------------------------------------
# ۶. اعمال فایروال (Anti-RST / Kernel Bypass)
# ---------------------------------------------
echo -e "${GREEN}[+] تنظیم iptables برای جلوگیری از قطع ارتباط...${NC}"

# حذف رول‌های قدیمی برای جلوگیری از تکرار
iptables -t raw -D PREROUTING -p tcp --dport $PAQET_PORT -j NOTRACK 2>/dev/null
iptables -t raw -D OUTPUT -p tcp --sport $PAQET_PORT -j NOTRACK 2>/dev/null
iptables -t mangle -D OUTPUT -p tcp --sport $PAQET_PORT --tcp-flags RST RST -j DROP 2>/dev/null

# اعمال رول‌های جدید
iptables -t raw -A PREROUTING -p tcp --dport $PAQET_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $PAQET_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $PAQET_PORT --tcp-flags RST RST -j DROP

netfilter-persistent save > /dev/null 2>&1

# ---------------------------------------------
# ۷. ساخت کانفیگ
# ---------------------------------------------
mkdir -p /etc/paqet
CONFIG_FILE="/etc/paqet/config.yaml"

if [ "$ROLE_CHOICE" == "1" ]; then
    # --- SERVER CONFIG ---
    cat <<EOF > $CONFIG_FILE
role: "server"
log:
  level: "info"
listen:
  addr: ":$PAQET_PORT"
network:
  interface: "$DEFAULT_IFACE"
  ipv4:
    addr: "$SERVER_IP:$PAQET_PORT"
    router_mac: "$GATEWAY_MAC"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$PAQET_KEY"
EOF

elif [ "$ROLE_CHOICE" == "2" ]; then
    # --- CLIENT CONFIG ---
    read -p "آی‌پی سرور خارج را وارد کنید: " FOREIGN_IP

    # فعال‌سازی IP Forwarding برای عبور ترافیک
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-paqet.conf
    sysctl -p /etc/sysctl.d/99-paqet.conf > /dev/null

    cat <<EOF > $CONFIG_FILE
role: "client"
log:
  level: "info"
# پورت 4789 برای تانل VXLAN/GRE رزرو می‌شود
forward:
  - listen: "0.0.0.0:4789"
    target: "127.0.0.1:4789"
    protocol: "udp"
network:
  interface: "$DEFAULT_IFACE"
  ipv4:
    addr: "$SERVER_IP:0"
    router_mac: "$GATEWAY_MAC"
server:
  addr: "$FOREIGN_IP:$PAQET_PORT"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$PAQET_KEY"
EOF
fi

# ---------------------------------------------
# ۸. ساخت و اجرای سرویس
# ---------------------------------------------
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$TARGET_BIN run -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paqet
systemctl restart paqet

echo -e "${BLUE}-------------------------------------------------${NC}"
if systemctl is-active --quiet paqet; then
    echo -e "${GREEN}SUCCESS: سرویس با موفقیت روی معماری $ARCH اجرا شد!${NC}"
    echo -e "وضعیت: Active (Running)"
else
    echo -e "${RED}ERROR: سرویس اجرا نشد.${NC}"
    systemctl status paqet --no-pager
fi