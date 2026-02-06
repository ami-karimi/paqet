#!/bin/bash

# رنگ‌ها برای زیبایی خروجی
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# بررسی روت بودن
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً اسکریپت را با sudo اجرا کنید.${NC}"
  exit 1
fi

echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#      اسکریپت جامع نصب و راه‌اندازی Paqet      #${NC}"
echo -e "${BLUE}#################################################${NC}"

# ۱. تشخیص معماری سیستم
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo -e "${RED}معماری $ARCH پشتیبانی نمی‌شود.${NC}"
    exit 1
fi
echo -e "${YELLOW}[*] معماری شناسایی شده: $PAQET_ARCH${NC}"

# ۲. نصب پیش‌نیازها
echo -e "${GREEN}[+] در حال نصب ابزارهای مورد نیاز...${NC}"
apt-get update -qq && apt-get install -y libpcap-dev iptables iptables-persistent net-tools curl wget file -qq

# ۳. دانلود هوشمند باینری
TARGET_BIN="/usr/local/bin/paqet"
DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.13/paqet_linux_${PAQET_ARCH}"

echo -e "${GREEN}[+] در حال دانلود Paqet از گیت‌هاب...${NC}"
systemctl stop paqet 2>/dev/null
rm -f $TARGET_BIN

# استفاده از curl -L برای دنبال کردن ریدایرکت‌ها (حل مشکل فایل خراب)
curl -L -o $TARGET_BIN "$DOWNLOAD_URL"

if [[ ! $(file $TARGET_BIN) == *"ELF"* ]]; then
    echo -e "${RED}[!] خطای دانلود: فایل باینری دریافت نشد. در حال تلاش مجدد با متد جایگزین...${NC}"
    wget -q --show-progress -O $TARGET_BIN "$DOWNLOAD_URL"
fi

chmod +x $TARGET_BIN
echo -e "${GREEN}[+] فایل باینری با موفقیت آماده شد.${NC}"

# ۴. جمع‌آوری اطلاعات شبکه
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
ping -c 1 $GW_IP > /dev/null 2>&1
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

# ۵. پرسش از کاربر
echo -e "${BLUE}-------------------------------------------------${NC}"
echo "نقش این سرور چیست؟"
echo "1) خارج (Server)"
echo "2) ایران (Client)"
read -p "انتخاب (1 یا 2): " CHOICE

read -p "پورت تانل Paqet (پیش‌فرض 9999): " P_PORT
P_PORT=${P_PORT:-9999}

read -p "پسورد تانل (باید در هر دو سمت یکی باشد): " P_KEY
if [ -z "$P_KEY" ]; then echo "پسورد اجباری است."; exit 1; fi

# ۶. تنظیمات فایروال (بسیار حیاتی برای Paqet)
echo -e "${GREEN}[+] تنظیم قوانین فایروال برای عبور از هسته سیستم‌عامل...${NC}"
iptables -t raw -F 2>/dev/null
iptables -t raw -A PREROUTING -p tcp --dport $P_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $P_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP
netfilter-persistent save > /dev/null 2>&1

# ۷. ایجاد فایل کانفیگ
mkdir -p /etc/paqet
CONF="/etc/paqet/config.yaml"

if [ "$CHOICE" == "1" ]; then
    # کانفیگ سرور خارج
    cat <<EOF > $CONF
role: "server"
log:
  level: "info"
listen:
  addr: ":$P_PORT"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$LOCAL_IP:$P_PORT"
    router_mac: "$GW_MAC"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$P_KEY"
EOF
else
    # کانفیگ سرور ایران
    read -p "آی‌پی سرور خارج را وارد کنید: " REMOTE_IP
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-paqet.conf
    sysctl -p /etc/sysctl.d/99-paqet.conf > /dev/null

    cat <<EOF > $CONF
role: "client"
log:
  level: "info"
forward:
  - listen: "0.0.0.0:4789"
    target: "127.0.0.1:4789"
    protocol: "udp"
network:
  interface: "$IFACE"
  ipv4:
    addr: "$LOCAL_IP:0"
    router_mac: "$GW_MAC"
server:
  addr: "$REMOTE_IP:$P_PORT"
transport:
  protocol: "kcp"
  kcp:
    block: "aes"
    key: "$P_KEY"
EOF
fi

# ۸. ساخت سرویس سیستمی
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$TARGET_BIN run -c $CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ۹. اجرا و پایان
systemctl daemon-reload
systemctl enable paqet
systemctl restart paqet

echo -e "${BLUE}-------------------------------------------------${NC}"
if systemctl is-active --quiet paqet; then
    echo -e "${GREEN}✓ تانل Paqet با موفقیت فعال شد!${NC}"
    echo -e "برای مشاهده وضعیت: ${YELLOW}systemctl status paqet${NC}"
    echo -e "برای مشاهده لاگ‌ها: ${YELLOW}journalctl -u paqet -f${NC}"
else
    echo -e "${RED}خطا در اجرای سرویس. لاگ‌ها را بررسی کنید.${NC}"
fi