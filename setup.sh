#!/bin/bash

# تنظیم دقیق ورژن طبق لینک شما
VERSION="v1.0.0-alpha.14"

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "لطفاً با sudo اجرا کنید"; exit 1; fi

# ۱. تشخیص معماری (تبدیل x86_64 به amd64)
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo "معماری پشتیبانی نمی‌شود"
    exit 1
fi

# ۲. ساخت دقیق اسم فایل طبق الگوی لینک شما
# فرمت: paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
FILE_NAME="paqet-linux-${PAQET_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/${FILE_NAME}"
TARGET_BIN="/usr/local/bin/paqet"

echo -e "${YELLOW}[*] لینک دقیق دانلود: ${DOWNLOAD_URL}${NC}"

# ۳. دانلود و نصب
apt-get update -qq && apt-get install -y libpcap-dev iptables-persistent wget tar -qq

systemctl stop paqet 2>/dev/null
rm -f /tmp/paqet.tar.gz
rm -f $TARGET_BIN

echo -e "${GREEN}[+] در حال دانلود...${NC}"
wget -O /tmp/paqet.tar.gz "$DOWNLOAD_URL"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[+] دانلود شد. در حال اکسترکت...${NC}"
    # اکسترکت در پوشه tmp
    tar -xzf /tmp/paqet.tar.gz -C /tmp/

    # پیدا کردن فایل اجرایی (چون ممکن است داخل یک پوشه باشد یا اسمش فرق کند)
    # ما دنبال فایلی می‌گردیم که اسمش paqet باشد یا شبیه آن
    FIND_PATH=$(find /tmp -type f -name "paqet" | head -n 1)

    # اگر پیدا نشد، شاید اسمش paqet-linux-amd64... باشد
    if [ -z "$FIND_PATH" ]; then
        FIND_PATH=$(find /tmp -name "paqet-linux-*" -type f | head -n 1)
    fi

    if [ -n "$FIND_PATH" ]; then
        mv "$FIND_PATH" $TARGET_BIN
        chmod +x $TARGET_BIN
        echo -e "${GREEN}[✓] نصب موفقیت‌آمیز بود.${NC}"
    else
        echo -e "${RED}[!] فایل اکسترکت شد اما باینری پیدا نشد. محتویات /tmp را چک کنید.${NC}"
        ls -R /tmp
        exit 1
    fi
else
    echo -e "${RED}[FATAL] دانلود انجام نشد. لینک یا شبکه را بررسی کنید.${NC}"
    exit 1
fi

# ۴. ادامه تنظیمات (کانفیگ و سرویس)
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

echo "-------------------------------------------------"
read -p "نقش سرور (1: خارج، 2: ایران): " CHOICE
read -p "پورت تانل Paqet (پیش‌فرض 9999): " P_PORT
P_PORT=${P_PORT:-9999}
read -p "رمز عبور تانل: " P_KEY

# فایروال (بسیار مهم)
iptables -t raw -F
iptables -t raw -A PREROUTING -p tcp --dport $P_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $P_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP
netfilter-persistent save > /dev/null 2>&1

mkdir -p /etc/paqet
CONF="/etc/paqet/config.yaml"

if [ "$CHOICE" == "1" ]; then
    # Server Mode
    cat <<EOF > $CONF
role: "server"
log: { level: "info" }
listen: { addr: ":$P_PORT" }
network:
  interface: "$IFACE"
  ipv4: { addr: "$LOCAL_IP:$P_PORT", router_mac: "$GW_MAC" }
transport:
  protocol: "kcp"
  kcp: { block: "aes", key: "$P_KEY" }
EOF
else
    # Client Mode (Iran)
    read -p "آی‌پی سرور خارج: " REMOTE_IP
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-paqet.conf
    sysctl -p /etc/sysctl.d/99-paqet.conf > /dev/null
    cat <<EOF > $CONF
role: "client"
log: { level: "info" }
forward:
  - { listen: "0.0.0.0:4789", target: "127.0.0.1:4789", protocol: "udp" }
network:
  interface: "$IFACE"
  ipv4: { addr: "$LOCAL_IP:0", router_mac: "$GW_MAC" }
server: { addr: "$REMOTE_IP:$P_PORT" }
transport:
  protocol: "kcp"
  kcp: { block: "aes", key: "$P_KEY" }
EOF
fi

# سرویس
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel
After=network.target
[Service]
ExecStart=$TARGET_BIN run -c $CONF
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable paqet && systemctl restart paqet
echo -e "${GREEN}✓ تمام شد! وضعیت سرویس: systemctl status paqet${NC}"