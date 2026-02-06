#!/bin/bash

# مشخصات آخرین نسخه
VERSION="v1.0.0-alpha.14"

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo "لطفاً با sudo اجرا کنید"; exit 1; fi

# ۱. تشخیص معماری
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then PAQET_ARCH="amd64"; else PAQET_ARCH="arm64"; fi

# ۲. نصب پیش‌نیازها
apt-get update -qq && apt-get install -y libpcap-dev iptables-persistent curl wget file -qq

# ۳. متد دانلود اصلاح شده (استفاده از لینک مستقیم ریلیس)
TARGET_BIN="/usr/local/bin/paqet"
URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/paqet_linux_${PAQET_ARCH}"

echo -e "${YELLOW}[*] در حال تلاش برای دانلود نسخه ${VERSION} مخصوص ${PAQET_ARCH}...${NC}"

# تلاش برای دانلود با پارامترهای بهینه
wget -O $TARGET_BIN "$URL" || curl -L -o $TARGET_BIN "$URL"

# بررسی سلامت فایل
if [[ ! $(file $TARGET_BIN) == *"ELF"* ]]; then
    echo -e "${RED}[!] دانلود مستقیم ناموفق بود. احتمالاً به دلیل محدودیت شبکه.${NC}"
    echo -e "${YELLOW}[💡] راه حل دستی:${NC}"
    echo "۱. فایل paqet_linux_${PAQET_ARCH} را از لینک زیر در کامپیوتر خود دانلود کنید:"
    echo "$URL"
    echo "۲. آن را به مسیر $TARGET_BIN در این سرور آپلود کنید."
    echo "۳. سپس این اسکریپت را دوباره اجرا کنید."
    exit 1
fi

chmod +x $TARGET_BIN
echo -e "${GREEN}[✓] فایل باینری با موفقیت تایید شد.${NC}"

# ۴. گرفتن اطلاعات شبکه (مشابه قبل)
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

# ۵. پیکربندی (مشابه سناریوی شما)
echo "-------------------------------------------------"
read -p "نقش سرور (1: خارج، 2: ایران): " CHOICE
read -p "پورت تانل (پیش‌فرض 9999): " P_PORT
P_PORT=${P_PORT:-9999}
read -p "رمز عبور: " P_KEY

# ۶. قوانین فایروال (Raw Socket Bypass)
iptables -t raw -F
iptables -t raw -A PREROUTING -p tcp --dport $P_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $P_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP
netfilter-persistent save > /dev/null 2>&1

# ۷. ایجاد کانفیگ و سرویس
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
    read -p "آی‌پی خارج: " REMOTE_IP
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

# ۸. سرویس Systemd
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel
After=network.target
[Service]
ExecStart=$TARGET_BIN run -c $CONF
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable paqet && systemctl restart paqet
echo -e "${GREEN}✓ انجام شد! وضعیت را چک کنید: systemctl status paqet${NC}"