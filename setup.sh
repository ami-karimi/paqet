#!/bin/bash

# نسخه جدید
VERSION="v1.0.0-alpha.14"

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "لطفاً با sudo اجرا کنید"; exit 1; fi

# ۱. تشخیص معماری
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
else
    PAQET_ARCH="arm64"
fi

# ۲. نصب پیش‌نیازها
apt-get update -qq && apt-get install -y libpcap-dev iptables-persistent curl wget file tar -qq

# ۳. دانلود و استخراج (Extraction)
TARGET_BIN="/usr/local/bin/paqet"
# نام فایل بر اساس فرمت جدید گیت‌هاب
FILE_NAME="paqet-linux-${PAQET_ARCH}-${VERSION}.tar.gz"
URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/${FILE_NAME}"

echo -e "${YELLOW}[*] در حال دانلود و استخراج نسخه ${VERSION}...${NC}"

# پاکسازی فایل‌های قدیمی
systemctl stop paqet 2>/dev/null
rm -f $TARGET_BIN

# دانلود فایل فشرده
wget -O /tmp/paqet.tar.gz "$URL"

if [ $? -eq 0 ]; then
    # استخراج فایل باینری از داخل آرشیو
    tar -xzf /tmp/paqet.tar.gz -C /tmp/
    # پیدا کردن فایل استخراج شده (نام فایل داخل آرشیو معمولا متفاوت است)
    # این دستور فایل اصلی را پیدا کرده و به مسیر نهایی منتقل می‌کند
    mv /tmp/paqet-linux-${PAQET_ARCH}* $TARGET_BIN 2>/dev/null || mv /tmp/paqet $TARGET_BIN 2>/dev/null

    chmod +x $TARGET_BIN
    rm /tmp/paqet.tar.gz
    echo -e "${GREEN}[✓] فایل باینری با موفقیت استخراج و نصب شد.${NC}"
else
    echo -e "${RED}[!] دانلود شکست خورد. لطفاً لینک را چک کنید.${NC}"
    exit 1
fi

# ۴. گرفتن اطلاعات شبکه (مشابه قبل)
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

# ۵. پیکربندی تعاملی
echo "-------------------------------------------------"
read -p "نقش سرور (1: خارج، 2: ایران): " CHOICE
read -p "پورت تانل Paqet (مثلاً 9999): " P_PORT
P_PORT=${P_PORT:-9999}
read -p "رمز عبور تانل: " P_KEY

# ۶. فایروال
iptables -t raw -F
iptables -t raw -A PREROUTING -p tcp --dport $P_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $P_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP
netfilter-persistent save > /dev/null 2>&1

# ۷. فایل کانفیگ
mkdir -p /etc/paqet
CONF="/etc/paqet/config.yaml"

if [ "$CHOICE" == "1" ]; then
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

# ۸. سرویس
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel Service
After=network.target
[Service]
ExecStart=$TARGET_BIN run -c $CONF
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable paqet && systemctl restart paqet

echo -e "${BLUE}-------------------------------------------------${NC}"
if systemctl is-active --quiet paqet; then
    echo -e "${GREEN}✓ تانل Paqet با موفقیت اجرا شد!${NC}"
else
    echo -e "${RED}⚠ مشکلی در اجرا وجود دارد. دستور زیر را بزنید:${NC}"
    echo "journalctl -u paqet -n 50"
fi