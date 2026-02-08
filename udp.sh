#!/bin/bash

# --- Config ---
# آی‌پی سرور خارج (که گفتی اینه)
REMOTE_IP="19.19.12.2"
# پورتی که ترافیک فیک شده از اینترنت رد میشه (باید روی فایروال خارج باز باشه)
RAW_PORT=443
# پورتی که وایرگارد/Amnezia روی اون گوش میده (همون پورتی که توی کانفیگ awg0 داری)
WG_PORT=51820
# پسورد رمزنگاری بین دو سرور (حتماً عوضش کن)
PASSWORD="MySuperSecretPassword123"

# --- Detect OS & Arch ---
if [[ $(uname -m) == "x86_64" ]]; then
    ARCH="amd64"
elif [[ $(uname -m) == "aarch64" ]]; then
    ARCH="arm64"
else
    echo "Unsupported Architecture"
    exit 1
fi

# --- 1. Download UDP2RAW ---
echo "Downloading udp2raw..."
mkdir -p /opt/udp2raw
cd /opt/udp2raw
wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200818.0/udp2raw_binaries.tar.gz
tar -xzvf udp2raw_binaries.tar.gz > /dev/null
mv udp2raw_${ARCH} udp2raw_bin
chmod +x udp2raw_bin

# --- 2. Ask Role ---
echo ""
echo "------------------------------------------------"
echo "Select Role for this Server:"
echo "1) Foreign Server (19.19.12.2)"
echo "2) Iran Server (Client)"
echo "------------------------------------------------"
read -p "Select [1-2]: " ROLE

if [ "$ROLE" == "1" ]; then
    # --- SERVER (FOREIGN) ---
    # Listen on TCP 443 (Internet), Forward to UDP 51820 (Local WireGuard)
    CMD="/opt/udp2raw/udp2raw_bin -s -l 0.0.0.0:${RAW_PORT} -r 127.0.0.1:${WG_PORT} -k ${PASSWORD} --raw-mode faketcp -a"
    echo "Setting up SERVER mode on port $RAW_PORT -> routing to local WG port $WG_PORT..."

elif [ "$ROLE" == "2" ]; then
    # --- CLIENT (IRAN) ---
    # Listen on UDP 51820 (Local), Forward to TCP 443 (Remote IP)
    # Note: We bind to 127.0.0.1 locally so only local WireGuard sees it
    CMD="/opt/udp2raw/udp2raw_bin -c -l 127.0.0.1:${WG_PORT} -r ${REMOTE_IP}:${RAW_PORT} -k ${PASSWORD} --raw-mode faketcp -a"
    echo "Setting up CLIENT mode connecting to $REMOTE_IP:$RAW_PORT..."
else
    echo "Invalid option."
    exit 1
fi

# --- 3. Create Service ---
cat <<EOF > /etc/systemd/system/udp2raw.service
[Unit]
Description=UDP2RAW Tunnel
After=network.target

[Service]
ExecStart=${CMD}
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# --- 4. Start ---
systemctl daemon-reload
systemctl enable udp2raw
systemctl restart udp2raw

echo ""
echo "✅ UDP2RAW installed and running!"
echo "Check status with: systemctl status udp2raw"