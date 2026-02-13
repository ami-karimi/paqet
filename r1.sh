#!/bin/bash

# رنگ‌ها برای زیبایی خروجی
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# بررسی دسترسی روت
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}این اسکریپت باید با دسترسی root اجرا شود.${NC}"
   exit 1
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}   نصب‌کننده هوشمند UDP2RAW (FakeTCP)   ${NC}"
echo -e "${BLUE}=======================================${NC}"

# ۱. تشخیص معماری سیستم
ARCH=$(uname -m)
echo -e "${YELLOW}[+] در حال تشخیص معماری سیستم: $ARCH ${NC}"

case $ARCH in
    x86_64)
        BIN_NAME="udp2raw_amd64"
        ;;
    x86)
        BIN_NAME="udp2raw_x86"
        ;;
    aarch64|arm64)
        BIN_NAME="udp2raw_arm" # معمولاً نسخه arm روی aarch64 هم کار می‌کند یا باید نسخه خاص کامپایل شود. اینجا از نسخه جنرال استفاده می‌کنیم.
        ;;
    *)
        echo -e "${RED}معماری $ARCH پشتیبانی نمی‌شود.${NC}"
        exit 1
        ;;
esac

# ۲. دانلود و نصب
if [ -f "/usr/local/bin/udp2raw" ]; then
    echo -e "${GREEN}[+] udp2raw قبلاً نصب شده است.${NC}"
else
    echo -e "${YELLOW}[+] در حال دانلود udp2raw...${NC}"
    # لینک دانلود نسخه باینری (می‌توانید نسخه را تغییر دهید)
    wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20230206.0/udp2raw_binaries.tar.gz

    if [ $? -ne 0 ]; then
        echo -e "${RED}دانلود ناموفق بود. اتصال اینترنت را چک کنید.${NC}"
        exit 1
    fi

    tar -xzvf udp2raw_binaries.tar.gz > /dev/null
    cp "$BIN_NAME" /usr/local/bin/udp2raw
    chmod +x /usr/local/bin/udp2raw

    # تمیزکاری
    rm udp2raw_binaries.tar.gz version.txt 2>/dev/null
    rm udp2raw_* 2>/dev/null

    echo -e "${GREEN}[+] نصب با موفقیت انجام شد.${NC}"
fi

# ۳. دریافت تنظیمات از کاربر
echo -e "\n${BLUE}--- پیکربندی ---${NC}"
echo "لطفاً نقش این سرور را انتخاب کنید:"
echo "1) سرور (Server) - معمولاً سرور خارج"
echo "2) کلاینت (Client) - معمولاً سرور ایران"
read -p "انتخاب شما (1/2): " ROLE

read -p "رمز عبور (Password) برای تانل: " PASSWORD
read -p "پورت FakeTCP (پیشنهاد: 443 یا 8443): " RAW_PORT

if [ "$ROLE" == "1" ]; then
    # تنظیمات سرور
    read -p "پورت سرویس اصلی (مثلاً پورت WireGuard/OpenVPN): " TARGET_PORT
    read -p "آی‌پی سرویس اصلی (معمولاً 127.0.0.1): " TARGET_IP

    # فلگ -a برای اضافه کردن خودکار رول iptables است
    CMD="/usr/local/bin/udp2raw -s -l0.0.0.0:$RAW_PORT -r $TARGET_IP:$TARGET_PORT -k $PASSWORD --raw-mode faketcp -a"
    SERVICE_NAME="udp2raw-server"

elif [ "$ROLE" == "2" ]; then
    # تنظیمات کلاینت
    read -p "آی‌پی سرور مقابل (Remote IP): " REMOTE_IP
    read -p "پورت لوکال برای گوش دادن (مثلاً 1080): " LOCAL_PORT

    CMD="/usr/local/bin/udp2raw -c -l0.0.0.0:$LOCAL_PORT -r $REMOTE_IP:$RAW_PORT -k $PASSWORD --raw-mode faketcp -a"
    SERVICE_NAME="udp2raw-client"
else
    echo -e "${RED}انتخاب نامعتبر.${NC}"
    exit 1
fi

# ۴. ساخت سرویس Systemd
echo -e "\n${YELLOW}[+] در حال ایجاد سرویس Systemd...${NC}"

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=UDP2RAW Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=$CMD
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

# ۵. فعال‌سازی و اجرا
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}

echo -e "${GREEN}---------------------------------------------${NC}"
echo -e "${GREEN} تانل با موفقیت راه‌اندازی شد! ${NC}"
echo -e " وضعیت سرویس: systemctl status ${SERVICE_NAME}"
echo -e " مشاهده لاگ: journalctl -u ${SERVICE_NAME} -f"
echo -e "${GREEN}---------------------------------------------${NC}"

# چک کردن وضعیت
sleep 2
systemctl status ${SERVICE_NAME} --no-pager