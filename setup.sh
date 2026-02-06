#!/bin/bash

# رنگ‌ها برای نمایش بهتر
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# بررسی دسترسی روت
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}لطفاً اسکریپت را با دسترسی root اجرا کنید (sudo).${NC}"
  exit
fi

echo -e "${BLUE}#################################################${NC}"
echo -e "${BLUE}#     نصب‌کننده خودکار Paqet برای تانلینگ     #${NC}"
echo -e "${BLUE}#################################################${NC}"

# ۱. نصب پیش‌نیازها
echo -e "${GREEN}[+] در حال آپدیت مخازن و نصب پیش‌نیازها (libpcap, iptables)...${NC}"
apt-get update -qq
apt-get install -y libpcap-dev iptables iptables-persistent net-tools curl wget -qq

# ۲. دریافت اطلاعات شبکه به صورت خودکار
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
SERVER_IP=$(curl -s ifconfig.me)
GATEWAY_IP=$(ip route | grep default | awk '{print $3}' | head -n1)

# پینگ به گیت‌وی برای اطمینان از پر شدن جدول ARP
ping -c 1 $GATEWAY_IP > /dev/null 2>&1
GATEWAY_MAC=$(ip neigh show $GATEWAY_IP | awk '{print $5}')

echo -e "${GREEN}[+] اطلاعات شبکه شناسایی شد:${NC}"
echo -e "    اینترفیس: $DEFAULT_IFACE"
echo -e "    آی‌پی سرور: $SERVER_IP"
echo -e "    گیت‌وی: $GATEWAY_IP ($GATEWAY_MAC)"
echo "-------------------------------------------------"

# ۳. دریافت تنظیمات از کاربر
echo -e "${BLUE}لطفاً نقش این سرور را انتخاب کنید:${NC}"
echo "1) سرور خارج (Server Mode - مقصد ترافیک)"
echo "2) سرور ایران (Client Mode - شروع تانل)"
read -p "گزینه (1 یا 2): " ROLE_CHOICE

read -p "یک پورت برای ارتباط Paqet وارد کنید (پیش‌فرض 9999): " PAQET_PORT
PAQET_PORT=${PAQET_PORT:-9999}

read -p "یک رمز عبور قوی برای تانل وارد کنید: " PAQET_KEY

if [ -z "$PAQET_KEY" ]; then
    echo -e "${RED}رمز عبور نمی‌تواند خالی باشد!${NC}"
    exit 1
fi

# ۴. دانلود Paqet
echo -e "${GREEN}[+] در حال دانلود Paqet...${NC}"
# لینک نسخه لینوکس ۶۴ بیتی (می‌توانید نسخه را تغییر دهید)
wget -q -O /usr/local/bin/paqet https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.13/paqet_linux_amd64
chmod +x /usr/local/bin/paqet

# ۵. اعمال قوانین فایروال (بسیار مهم برای Paqet)
echo -e "${GREEN}[+] در حال تنظیم قوانین iptables برای دور زدن کرنل...${NC}"

# پاک کردن قوانین قبلی مرتبط اگر وجود داشته باشد
iptables -t raw -D PREROUTING -p tcp --dport $PAQET_PORT -j NOTRACK 2>/dev/null
iptables -t raw -D OUTPUT -p tcp --sport $PAQET_PORT -j NOTRACK 2>/dev/null
iptables -t mangle -D OUTPUT -p tcp --sport $PAQET_PORT --tcp-flags RST RST -j DROP 2>/dev/null

# اعمال قوانین جدید
iptables -t raw -A PREROUTING -p tcp --dport $PAQET_PORT -j NOTRACK
iptables -t raw -A OUTPUT -p tcp --sport $PAQET_PORT -j NOTRACK
iptables -t mangle -A OUTPUT -p tcp --sport $PAQET_PORT --tcp-flags RST RST -j DROP

# ذخیره تنظیمات فایروال
netfilter-persistent save > /dev/null 2>&1

# ۶. ساخت فایل کانفیگ
mkdir -p /etc/paqet
CONFIG_FILE="/etc/paqet/config.yaml"

if [ "$ROLE_CHOICE" == "1" ]; then
    # --- تنظیمات سرور خارج ---
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
    # --- تنظیمات سرور ایران ---
    read -p "آی‌پی سرور خارج را وارد کنید: " FOREIGN_IP

    # فعال‌سازی IP Forwarding
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-paqet.conf
    sysctl -p /etc/sysctl.d/99-paqet.conf > /dev/null

    cat <<EOF > $CONFIG_FILE
role: "client"
log:
  level: "info"
# فوروارد کردن ترافیک GRE (UDP encapsulated) یا هر پورتی که نیاز دارید
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

# ۷. ساخت سرویس Systemd برای اجرای دائم
echo -e "${GREEN}[+] در حال ساخت سرویس systemd...${NC}"
cat <<EOF > /etc/systemd/system/paqet.service
[Unit]
Description=Paqet Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/paqet run -c /etc/paqet/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ۸. فعال‌سازی و اجرا
systemctl daemon-reload
systemctl enable paqet
systemctl restart paqet

echo -e "${BLUE}#################################################${NC}"
if systemctl is-active --quiet paqet; then
    echo -e "${GREEN}✓ Paqet با موفقیت نصب و اجرا شد!${NC}"
    echo -e "  فایل کانفیگ: $CONFIG_FILE"
    echo -e "  برای مشاهده لاگ‌ها: journalctl -u paqet -f"
else
    echo -e "${RED}⚠ سرویس اجرا نشد. لطفاً لاگ‌ها را بررسی کنید.${NC}"
fi
echo -e "${BLUE}#################################################${NC}"