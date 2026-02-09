#!/bin/bash
set -e

# ==========================================
#   Multi-Instance Hybrid Tunnel
#   udp2raw(faketcp) + WireGuard + GRE
#   ECMP Enabled | High Throughput
# ==========================================

# --------- CONFIG ----------
INSTANCES=3

RAW_PORTS=(443 8443 80)
WG_PORTS=(55551 55552 55553)
SUBNET_BASE=10.200

WG_MTU=1280

# ---------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

apt-get update -y
apt-get install -y wireguard-tools iptables-persistent wget tar ethtool

# ---- udp2raw ----
mkdir -p /opt/udp2raw && cd /opt/udp2raw
if [ ! -f udp2raw_bin ]; then
  wget -q https://github.com/wangyu-/udp2raw-tunnel/releases/download/20200818.0/udp2raw_binaries.tar.gz
  tar -xzf udp2raw_binaries.tar.gz
  mv udp2raw_amd64 udp2raw_bin 2>/dev/null || mv udp2raw_x86 udp2raw_bin
  chmod +x udp2raw_bin
fi

# ---- WG keys ----
mkdir -p /etc/wireguard
if [ ! -f /etc/wireguard/privatekey ]; then
  wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
fi

PRIV_KEY=$(cat /etc/wireguard/privatekey)
PUB_KEY=$(cat /etc/wireguard/publickey)

# ---- sysctl tuning ----
cat <<EOF >/etc/sysctl.d/99-udp2raw.conf
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

IFACE=$(ip route | awk '/default/ {print $5}')

ethtool -K $IFACE gro on gso on tso on rx on tx on 2>/dev/null || true

echo ""
echo "1) Foreign Server"
echo "2) Iran Server"
read -p "Select role: " ROLE

# ==================================================
# ================= FOREIGN ========================
# ==================================================
if [ "$ROLE" == "1" ]; then

read -p "UDP2RAW Password: " RAW_PASS
read -p "Iran Server Public Key: " PEER_PUB

for i in $(seq 1 $INSTANCES); do

RAW_PORT=${RAW_PORTS[$((i-1))]}
WG_PORT=${WG_PORTS[$((i-1))]}
WG_IF="wg$i"
SUBNET="${SUBNET_BASE}.${i}"

# ---- udp2raw server ----
cat <<EOF >/etc/systemd/system/udp2raw@$i.service
[Unit]
After=network.target
Description=udp2raw instance $i

[Service]
ExecStart=/opt/udp2raw/udp2raw_bin -s \
-l 0.0.0.0:${RAW_PORT} \
-r 127.0.0.1:${WG_PORT} \
-k ${RAW_PASS} \
--raw-mode faketcp \
--cipher-mode xor \
--auth-mode simple \
-a
Restart=always
CPUAffinity=$((i-1))

[Install]
WantedBy=multi-user.target
EOF

# ---- WireGuard ----
cat <<EOF >/etc/wireguard/${WG_IF}.conf
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${SUBNET}.1/24
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}

PostUp   = iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${SUBNET}.2/32
EOF

systemctl enable udp2raw@$i wg-quick@${WG_IF}

done

# ==================================================
# ================= IRAN ===========================
# ==================================================
else

read -p "Foreign Server IP: " REMOTE_IP
read -p "UDP2RAW Password: " RAW_PASS
read -p "Foreign Server Public Key: " PEER_PUB
read -p "MikroTik IP: " MK_REAL_IP
read -p "Iran Local IP: " IRAN_REAL_IP

GRE_IP_IRAN="172.16.200.1"
GRE_IP_MK="172.16.200.2"

for i in $(seq 1 $INSTANCES); do

RAW_PORT=${RAW_PORTS[$((i-1))]}
WG_PORT=${WG_PORTS[$((i-1))]}
WG_IF="wg$i"
SUBNET="${SUBNET_BASE}.${i}"

# ---- udp2raw client ----
cat <<EOF >/etc/systemd/system/udp2raw@$i.service
[Unit]
After=network.target
Description=udp2raw instance $i

[Service]
ExecStart=/opt/udp2raw/udp2raw_bin -c \
-l 127.0.0.1:${WG_PORT} \
-r ${REMOTE_IP}:${RAW_PORT} \
-k ${RAW_PASS} \
--raw-mode faketcp \
--cipher-mode xor \
--auth-mode simple \
-a
Restart=always
CPUAffinity=$((i-1))

[Install]
WantedBy=multi-user.target
EOF

# ---- WireGuard ----
cat <<EOF >/etc/wireguard/${WG_IF}.conf
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${SUBNET}.2/24
MTU = ${WG_MTU}
Table = off

[Peer]
PublicKey = ${PEER_PUB}
Endpoint = 127.0.0.1:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

systemctl enable udp2raw@$i wg-quick@${WG_IF}

done

# ---- GRE ----
cat <<EOF >/usr/local/bin/setup-gre.sh
#!/bin/bash
ip tunnel del gre1 2>/dev/null
ip tunnel add gre1 mode gre remote ${MK_REAL_IP} local ${IRAN_REAL_IP} ttl 255
ip addr add ${GRE_IP_IRAN}/30 dev gre1
ip link set gre1 up

iptables -t nat -A POSTROUTING -o wg+ -j MASQUERADE
iptables -A FORWARD -i gre1 -j ACCEPT
iptables -A FORWARD -o gre1 -j ACCEPT
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

chmod +x /usr/local/bin/setup-gre.sh

cat <<EOF >/etc/systemd/system/gre-tunnel.service
[Unit]
After=wg-quick@wg1.service
Description=GRE Tunnel

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-gre.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable gre-tunnel

# ---- ECMP ROUTE ----
ip route del default 2>/dev/null || true

CMD="ip route add default scope global"
for i in $(seq 1 $INSTANCES); do
  CMD+=" nexthop dev wg$i weight 1"
done
eval $CMD

fi

systemctl daemon-reload

for i in $(seq 1 $INSTANCES); do
  systemctl restart udp2raw@$i
  systemctl restart wg-quick@wg$i
done

[ "$ROLE" == "2" ] && systemctl restart gre-tunnel

echo "==================================="
echo "DONE ✔  Multi-Instance Active"
echo "Public Key: $PUB_KEY"
echo "==================================="
