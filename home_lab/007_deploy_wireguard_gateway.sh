#!/usr/bin/env bash
# ==============================================================================
# Script: 007_deploy_wireguard_gateway.sh
# Purpose: Configures and starts the WireGuard Hub on vpc-gateway (10.100.0.1/24),
#          binds UDP port 51820 on eth0, and applies outbound SNAT (MASQUERADE) on eth1.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

# Pre-flight check: Container presence and state
if ! sudo podman ps -q --filter "name=^vpc-gateway$" | grep -q .; then
  echo "ERROR: Container 'vpc-gateway' is not running."
  echo "Execute 005_deploy_gateway_and_baremetal.sh first."
  exit 1
fi

echo "${SEPARATOR}"
echo "STEP 1: GENERATE CRYPTOGRAPHIC KEYPAIR ON GATEWAY"
echo "[NOTE]   : Generates Curve25519 private and public keys inside vpc-gateway."
echo "[CAUSE]  : WireGuard authenticates each peer using Noise Protocol cryptokeys."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway sh -c 'mkdir -p /etc/wireguard && \\"
echo "    wg genkey | tee /etc/wireguard/gw_priv.key | wg pubkey > /etc/wireguard/gw_pub.key && \\"
echo "    chmod 600 /etc/wireguard/gw_priv.key'"
echo ""
echo "[WHY]:"
echo "  - Private key must remain strictly local to the gateway namespace (mode 0600)."
echo "  - Public key is shared with spoke nodes to authenticate inbound handshakes."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Gateway Public Key: <44-character base64 string>"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway sh -c "mkdir -p /etc/wireguard && \
  wg genkey | tee /etc/wireguard/gw_priv.key | wg pubkey > /etc/wireguard/gw_pub.key && \
  chmod 600 /etc/wireguard/gw_priv.key"

GW_PUB=$(sudo podman exec vpc-gateway cat /etc/wireguard/gw_pub.key)
echo "  Gateway Public Key : ${GW_PUB}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: PRE-FETCH OR INITIALIZE BARE-METAL SPOKE PUBLIC KEY"
echo "[NOTE]   : Obtains the public key of baremetal-node to configure the peer stanza."
echo "[CAUSE]  : WireGuard cryptokey routing requires the Hub to know the Spoke's public"
echo "           key and assign its dedicated tunnel IP before traffic can be decrypted."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node sh -c 'mkdir -p /etc/wireguard && \\"
echo "    test -f /etc/wireguard/bm_pub.key || \\"
echo "    (wg genkey | tee /etc/wireguard/bm_priv.key | wg pubkey > /etc/wireguard/bm_pub.key && chmod 600 /etc/wireguard/bm_priv.key)'"
echo ""
echo "[WHY]:"
echo "  - Ensures decoupled, idempotent script runs even if the gateway is provisioned first."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Bare-metal Public Key: <44-character base64 string>"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node sh -c "mkdir -p /etc/wireguard && \
  if [ ! -f /etc/wireguard/bm_pub.key ]; then \
    wg genkey | tee /etc/wireguard/bm_priv.key | wg pubkey > /etc/wireguard/bm_pub.key && \
    chmod 600 /etc/wireguard/bm_priv.key; \
  fi"

BM_PUB=$(sudo podman exec baremetal-node cat /etc/wireguard/bm_pub.key)
echo "  Bare-metal Public Key : ${BM_PUB}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: WRITE GATEWAY WIREGUARD CONFIGURATION (wg0.conf)"
echo "[NOTE]   : Configures interface wg0 (10.100.0.1/24), ListenPort 51820, and iptables SNAT."
echo "[CAUSE]  : [SNAT NECESSITY]: Private VPC nodes (Redis 172.29.0.20 and K8s 172.29.0.30)"
echo "           have default routes to the VPC bridge (172.29.0.1). They do not know about"
echo "           10.100.0.0/24. Applying MASQUERADE on eth1 rewrites the packet source to"
echo "           172.29.0.2, ensuring VPC return traffic flows back through the gateway."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  cat <<EOF > /etc/wireguard/wg0.conf"
echo "  [Interface]"
echo "  Address = 10.100.0.1/24"
echo "  ListenPort = 51820"
echo "  PrivateKey = \$(cat /etc/wireguard/gw_priv.key)"
echo "  PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE"
echo "  PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE"
echo ""
echo "  [Peer]"
echo "  PublicKey = ${BM_PUB}"
echo "  AllowedIPs = 10.100.0.10/32"
echo "  EOF"
echo ""
echo "[WHY]:"
echo "  - AllowedIPs = 10.100.0.10/32: Enforces cryptokey routing (only this spoke can send as .10)."
echo "  - ListenPort = 51820: Exposed on eth0 (172.28.0.2) for inbound UDP handshakes."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Configuration written successfully to /etc/wireguard/wg0.conf inside vpc-gateway."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway sh -c "cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/gw_priv.key)

# SNAT outbound traffic traversing eth1 into Provider A VPC
PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE

[Peer]
# Bare-Metal Node 01
PublicKey = ${BM_PUB}
AllowedIPs = 10.100.0.10/32
EOF
chmod 600 /etc/wireguard/wg0.conf
"
echo "  wg0.conf successfully created on vpc-gateway."
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: ACTIVATE WIREGUARD INTERFACE (wg0)"
echo "[NOTE]   : Invokes wg-quick to bring up virtual network device wg0."
echo "[CAUSE]  : Initializes the in-kernel WireGuard socket, applies IP assignments,"
echo "           and triggers PostUp iptables rules."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway sh -c 'wg-quick down wg0 2>/dev/null || true; wg-quick up wg0'"
echo ""
echo "[WHY]:"
echo "  - Safe down-then-up sequence ensures clean reload without lingering interfaces."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  [#] ip link add dev wg0 type wireguard"
echo "  [#] ip -4 address add 10.100.0.1/24 dev wg0"
echo "  [#] ip link set mtu 1420 up dev wg0"
echo "  [#] iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway sh -c "wg-quick down wg0 2>/dev/null || true; wg-quick up wg0"
echo "${SEPARATOR}"
