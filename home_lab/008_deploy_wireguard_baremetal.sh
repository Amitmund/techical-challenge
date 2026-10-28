#!/usr/bin/env bash
# ==============================================================================
# Script: 008_deploy_wireguard_baremetal.sh
# Purpose: Configures and activates the WireGuard Spoke on baremetal-node (10.100.0.10/24),
#          initiates the UDP handshake to the Hub, and routes 172.29.0.0/16 and
#          10.100.0.0/24 through wg0.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

# Pre-flight check: Container presence and state
if ! sudo podman ps -q --filter "name=^baremetal-node$" | grep -q .; then
  echo "ERROR: Container 'baremetal-node' is not running."
  echo "Execute 005_deploy_gateway_and_baremetal.sh first."
  exit 1
fi

echo "${SEPARATOR}"
echo "STEP 1: VERIFY OR GENERATE BARE-METAL KEYPAIR"
echo "[NOTE]   : Ensures baremetal-node has its Curve25519 keypair ready."
echo "[CAUSE]  : Noise protocol requires cryptographic identity on every spoke."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node sh -c 'mkdir -p /etc/wireguard && \\"
echo "    test -f /etc/wireguard/bm_priv.key || \\"
echo "    (wg genkey | tee /etc/wireguard/bm_priv.key | wg pubkey > /etc/wireguard/bm_pub.key && chmod 600 /etc/wireguard/bm_priv.key)'"
echo ""
echo "[WHY]:"
echo "  - Generates key if not already initialized during gateway deployment."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Bare-metal Public Key: <44-character base64 string>"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node sh -c "mkdir -p /etc/wireguard && \
  if [ ! -f /etc/wireguard/bm_priv.key ]; then \
    wg genkey | tee /etc/wireguard/bm_priv.key | wg pubkey > /etc/wireguard/bm_pub.key && \
    chmod 600 /etc/wireguard/bm_priv.key; \
  fi"

BM_PUB=$(sudo podman exec baremetal-node cat /etc/wireguard/bm_pub.key)
echo "  Bare-metal Public Key : ${BM_PUB}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: FETCH GATEWAY HUB PUBLIC KEY"
echo "[NOTE]   : Reads the public key from vpc-gateway to establish peer trust."
echo "[CAUSE]  : Spoke must encrypt packets using the Gateway's public key."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway cat /etc/wireguard/gw_pub.key"
echo ""
echo "[WHY]:"
echo "  - Establishes the authenticated asymmetric encryption channel."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Gateway Public Key: <44-character base64 string>"
echo ""
echo "[ACTUAL OUTPUT]:"
if ! sudo podman exec vpc-gateway test -f /etc/wireguard/gw_pub.key 2>/dev/null; then
  echo "  ERROR: Gateway public key not found. Run 007_deploy_wireguard_gateway.sh first!"
  exit 1
fi

GW_PUB=$(sudo podman exec vpc-gateway cat /etc/wireguard/gw_pub.key)
echo "  Gateway Public Key    : ${GW_PUB}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: WRITE BARE-METAL WIREGUARD CONFIGURATION (wg0.conf)"
echo "[NOTE]   : Configures wg0 (10.100.0.10/24), Endpoint, AllowedIPs, and Keepalive."
echo "[CAUSE]  : [SPLIT-TUNNEL & ALLOWED-IPS ROUTING NOTE]:"
echo "           - Endpoint = 172.28.0.2:51820 (Transit WAN IP of the Hub)."
echo "           - AllowedIPs = 172.29.0.0/16, 10.100.0.0/24: Tells the Linux kernel"
echo "             to route both VPC traffic AND overlay subnet traffic into wg0."
echo "             Non-VPC traffic (0.0.0.0/0) remains on the physical eth0 interface."
echo "           - PersistentKeepalive = 25: Sends empty packets every 25s to maintain"
echo "             state in intermediate NAT tables and edge firewalls."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  cat <<EOF > /etc/wireguard/wg0.conf"
echo "  [Interface]"
echo "  Address = 10.100.0.10/24"
echo "  PrivateKey = \$(cat /etc/wireguard/bm_priv.key)"
echo ""
echo "  [Peer]"
echo "  PublicKey = ${GW_PUB}"
echo "  Endpoint = 172.28.0.2:51820"
echo "  AllowedIPs = 172.29.0.0/16, 10.100.0.0/24"
echo "  PersistentKeepalive = 25"
echo "  EOF"
echo ""
echo "[WHY]:"
echo "  - Omitting 10.100.0.0/24 would prevent pinging the gateway tunnel IP (10.100.0.1)."
echo "  - Explicit CIDRs maintain a strict split-tunnel design."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Configuration written successfully to /etc/wireguard/wg0.conf on baremetal-node."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node sh -c "cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.10/24
PrivateKey = \$(cat /etc/wireguard/bm_priv.key)

[Peer]
PublicKey = ${GW_PUB}
Endpoint = 172.28.0.2:51820
AllowedIPs = 172.29.0.0/16, 10.100.0.0/24
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
"
echo "  wg0.conf successfully created on baremetal-node."
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: ACTIVATE WIREGUARD INTERFACE ON BARE-METAL NODE"
echo "[NOTE]   : Brings up wg0 using wg-quick and initiates the handshake."
echo "[CAUSE]  : Instantiates the wg0 device, applies IP 10.100.0.10/24, and injects"
echo "           routes for 172.29.0.0/16 and 10.100.0.0/24 into the routing table."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node sh -c 'wg-quick down wg0 2>/dev/null || true; wg-quick up wg0'"
echo ""
echo "[WHY]:"
echo "  - Immediately initiates an outbound UDP handshake toward the Hub."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  [#] ip link add dev wg0 type wireguard"
echo "  [#] ip -4 address add 10.100.0.10/24 dev wg0"
echo "  [#] ip link set mtu 1420 up dev wg0"
echo "  [#] ip -4 route add 172.29.0.0/16 dev wg0"
echo "  [#] ip -4 route add 10.100.0.0/24 dev wg0"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node sh -c "wg-quick down wg0 2>/dev/null || true; wg-quick up wg0"
echo "${SEPARATOR}"
