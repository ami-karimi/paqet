import socket
import os
import struct
import select
import sys
import fcntl
import itertools

# ================= CONFIGURATION (Must be identical on both sides) =================
# Simple XOR Key for obfuscation. The longer, the better.
# This makes the payload look like random noise to DPI.
XOR_KEY = b'MySecretKey_NoDPI_2024_Goes_Brrr'

# Custom Protocol Number (Between 143 and 253).
# We use 253 (Reserved for experimental/testing purposes).
CUSTOM_PROTO = 253

# Tunnel Interface Name
TUN_NAME = 'tun_stealth'

# MTU (Must be lower than 1500 to accommodate the outer IP header)
MTU = 1400
# ===================================================================================

# Linux constants for TUN interface creation
TUNSETIFF = 0x400454ca
IFF_TUN   = 0x0001
IFF_NO_PI = 0x1000

def create_tun_interface(dev_name):
    """Creates a virtual TUN interface."""
    tun_fd = os.open("/dev/net/tun", os.O_RDWR)
    ifr = struct.pack("16sH", dev_name.encode("utf-8"), IFF_TUN | IFF_NO_PI)
    fcntl.ioctl(tun_fd, TUNSETIFF, ifr)
    return tun_fd

def set_ip(dev_name, local_ip, peer_ip):
    """Configures IP address and MTU on the TUN interface."""
    os.system(f"ip link set dev {dev_name} mtu {MTU}")
    os.system(f"ip addr add {local_ip} peer {peer_ip} dev {dev_name}")
    os.system(f"ip link set {dev_name} up")
    print(f"✅ Interface {dev_name} is UP (Protocol: {CUSTOM_PROTO})")

def xor_data(data, key):
    """Simple XOR encryption/decryption function."""
    # Uses itertools.cycle to repeat the key over the data length
    return bytes(a ^ b for a, b in zip(data, itertools.cycle(key)))

def main(remote_ip, tun_local, tun_peer):
    # 1. Setup TUN Interface
    try:
        tun_fd = create_tun_interface(TUN_NAME)
        set_ip(TUN_NAME, tun_local, tun_peer)
    except Exception as e:
        print(f"❌ Error creating TUN (Do you have root privileges?): {e}")
        return

    # 2. Setup Raw Socket
    # We use SOCK_RAW to send packets with our custom protocol number (253)
    try:
        raw_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, CUSTOM_PROTO)
    except PermissionError:
        print("❌ Error: Raw sockets require root privileges (sudo).")
        return

    print(f"🛡️  Stealth Mode Active.")
    print(f"📡 Remote Endpoint: {remote_ip}")

    inputs = [tun_fd, raw_sock]

    while True:
        try:
            readable, _, _ = select.select(inputs, [], [])

            for source in readable:
                # --- CASE 1: Data from Local System (TUN) -> Send to Internet ---
                if source is tun_fd:
                    packet = os.read(tun_fd, MTU + 100)
                    if packet:
                        # Obfuscate (XOR) the packet so DPI cannot see the inner IP header
                        obfuscated_packet = xor_data(packet, XOR_KEY)

                        # Send to remote server (Kernel adds the outer IP header automatically)
                        raw_sock.sendto(obfuscated_packet, (remote_ip, 0))

                # --- CASE 2: Data from Internet (Raw Socket) -> Decrypt -> Send to System ---
                elif source is raw_sock:
                    raw_data, addr = raw_sock.recvfrom(MTU + 100)

                    # IMPORTANT: raw_sock includes the Outer IP Header.
                    # We must strip it to get our payload.
                    if len(raw_data) > 20:
                        version_ihl = raw_data[0]
                        ihl = version_ihl & 0x0F
                        ip_header_len = ihl * 4

                        # Extract the payload (which is our encrypted data)
                        encrypted_payload = raw_data[ip_header_len:]

                        if encrypted_payload:
                            # Decrypt (XOR)
                            decrypted_packet = xor_data(encrypted_payload, XOR_KEY)

                            # Write to TUN interface (Kernel handles the rest)
                            os.write(tun_fd, decrypted_packet)

        except KeyboardInterrupt:
            print("\n🛑 Tunnel stopped by user.")
            break
        except Exception as e:
            # Pass on minor network errors to keep the tunnel alive
            pass

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"Usage: sudo python3 stealth_tunnel.py <Remote_Public_IP> <Local_Tun_IP> <Peer_Tun_IP>")
        print("Example: sudo python3 stealth_tunnel.py 1.2.3.4 10.0.0.1 10.0.0.2")
        sys.exit(1)

    remote_public_ip = sys.argv[1]
    local_tun_ip = sys.argv[2]
    peer_tun_ip = sys.argv[3]

    main(remote_public_ip, local_tun_ip, peer_tun_ip)