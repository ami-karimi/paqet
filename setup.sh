#!/bin/bash

# ==========================================
#  Paqet Auto-Installer (Robust Extraction)
#  Version: v1.0.0-alpha.14
# ==========================================

# رنگ‌ها
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً با دسترسی root (sudo) اجرا کنید.${NC}"
  exit 1
fi

echo -e "${CYAN}#################################################${NC}"
echo -e "${CYAN}#        نصب‌کننده هوشمند تانل Paqet            #${NC}"
echo -e "${CYAN}#################################################${NC}"

# -----------------------------------------------
# ۱. تشخیص معماری سیستم
# -----------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    PAQET_ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    PAQET_ARCH="arm64"
else
    echo -e "${RED}معماری $ARCH پشتیبانی نمی‌شود.${NC}"
    exit 1
fi

# -----------------------------------------------
# ۲. نصب پیش‌نیازها
# -----------------------------------------------
echo -e "${GREEN}[+] در حال نصب ابزارهای مورد نیاز...${NC}"
apt-get update -qq
apt-get install -y libpcap-dev iptables iptables-persistent net-tools curl wget tar -qq

# -----------------------------------------------
# ۳. دانلود و نصب (منطق اصلاح شده)
# -----------------------------------------------
VERSION="v1.0.0-alpha.14"
FILE_NAME="paqet-linux-${PAQET_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/hanselime/paqet/releases/download/${VERSION}/${FILE_NAME}"
INSTALL_PATH="/usr/local/bin/paqet"
TEMP_DIR="/tmp/paqet_install"

echo -e "${YELLOW}[*] در حال دانلود نسخه ${VERSION}...${NC}"

# آماده‌سازی محیط تمیز
systemctl stop paqet 2>/dev/null
rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR
rm -f /tmp/paqet.tar.gz

# دانلود
wget -q --show-progress -O /tmp/paqet.tar.gz "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}[FATAL] دانلود فایل شکست خورد. اینترنت سرور را بررسی کنید.${NC}"
    exit 1
fi

echo -e "${GREEN}[+] دانلود شد. در حال اکسترکت و جستجوی فایل باینری...${NC}"
tar -xzf /tmp/paqet.tar.gz -C $TEMP_DIR

# پیدا کردن فایل اجرایی (بزرگترین فایل در پوشه اکسترکت شده)
# این روش تضمینی است چون فایل باینری همیشه حجمش از فایل‌های متنی بیشتر است
BINARY_FOUND=$(find $TEMP_DIR -type f -size +1M | head -n 1)

if [ -n "$BINARY_FOUND" ]; then
    echo -e "${GREEN}[✓] فایل اصلی پیدا شد: $BINARY_FOUND${NC}"
    cp "$BINARY_FOUND" $INSTALL_PATH
    chmod +x $INSTALL_PATH
else
    echo -e "${RED}[FATAL] فایل باینری در آرشیو پیدا نشد! محتویات:${NC}"
    ls -R $TEMP_DIR
    exit 1
fi

# پاکسازی
rm -rf $TEMP_DIR /tmp/paqet.tar.gz

# -----------------------------------------------
# ۴. دریافت اطلاعات شبکه
# -----------------------------------------------
IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
GW_IP=$(ip route | grep default | awk '{print $3}' | head -n1)
# پینگ برای پر کردن جدول ARP
ping -c 1 $GW_IP > /dev/null 2>&1
GW_MAC=$(ip neigh show $GW_IP | awk '{print $5}')
LOCAL_IP=$(curl -s ifconfig.me)

if [ -z "$GW_MAC" ]; then
    echo -e "${RED}هشدار: مک آدرس گیت‌وی پیدا نشد. لطفاً دستی وارد کنید.${NC}"
    read -p "Gateway MAC: " GW_MAC
fi

# -----------------------------------------------
# ۵. پیکربندی توسط کاربر
# -----------------------------------------------
echo -e "${CYAN}-------------------------------------------------${NC}"
echo "نقش این سرور را انتخاب کنید:"
echo "1) سرور خارج (Server Mode)"
echo "2) سرور ایران (Client Mode - متصل به میکروتیک)"
read -p "انتخاب (1 یا 2): " ROLE_CHOICE

read -p "پورت تانل Paqet (پیش‌فرض 9999): " P_PORT
P_PORT=${P_PORT:-9999}

read -p "رمز عبور تانل (یکسان در هر دو سرور): " P_KEY
if [ -z "$P_KEY" ]; then echo "رمز نمی‌تواند خالی باشد"; exit 1; fi

# -----------------------------------------------
# ۶. تنظیمات فایروال (Raw Socket Bypass)
# -----------------------------------------------
echo -e "${GREEN}[+] اعمال تنظیمات خاص فایروال...${NC}"
# حذف رول‌های تکراری
iptables -t raw -D PREROUTING -p tcp --dport $P_PORT -j NOTRACK 2>/dev/null
iptables -t raw -D OUTPUT -p tcp --sport $P_PORT -j NOTRACK 2>/dev/null
iptables -t mangle -D OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP 2>/dev/null

# اعمال رول‌ها
iptables -t raw -A PREROUTING -p tcp --dport $P_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $P_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $P_PORT --tcp-flags RST RST -j DROP

netfilter-persistent save > /dev/null 2>&1

# -----------------------------------------------
# ۷. ساخت فایل کانفیگ
# -----------------------------------------------
mkdir -p /etc/paqet
CONF="/etc/paqet/config.yaml"

if [ "$ROLE_CHOICE" == "1" ]; then
    # --- SERVER CONFIG ---
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
    # --- CLIENT CONFIG ---
    read -p "آی‌پی سرور خارج را وارد کنید: " REMOTE_IP

    # فعال‌سازی IP Forwarding
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-paqet.conf
    sysctl -p /etc/sysctl.d/99-paqet.conf > /dev/null

    cat <<EOF > $CONF
role: "client"
log: { level: "info" }
# فوروارد کردن پورت GRE (4789 UDP) به سمت سرور خارج
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

# -----------------------------------------------
# ۸. ساخت و اجرای سرویس
# -----------------------------------------------
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_PATH run -c $CONF
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paqet
systemctl restart paqet

echo -e "${CYAN}-------------------------------------------------${NC}"
if systemctl is-active --quiet paqet; then
    echo -e "${GREEN}✓ تانل با موفقیت نصب و اجرا شد!${NC}"
    if [ "$ROLE_CHOICE" == "2" ]; then
        echo -e "${YELLOW}نکته برای میکروتیک:${NC}"
        echo -e "در تنظیمات GRE میکروتیک:"
        echo -e "Remote Address = $LOCAL_IP (آی‌پی همین سرور ایران)"
        echo -e "Tunnel Port = 4789"
    fi
else
    echo -e "${RED}خطا: سرویس اجرا نشد. خروجی زیر را بررسی کنید:${NC}"
    journalctl -u paqet -n 20 --no-pager
fi