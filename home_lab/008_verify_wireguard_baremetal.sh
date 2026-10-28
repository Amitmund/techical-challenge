#!/usr/bin/env bash
# ==============================================================================
# Script: 008_verify_wireguard_baremetal.sh
# Purpose: Comprehensive validation of the Bare-Metal Spoke node:
#          1. WireGuard interface wg0 and IP 10.100.0.10/24.
#          2. Kernel routing table entries for VPC (172.29.0.0/16) and overlay.
#          3. Cryptographic handshake status and transfer counters.
#          4. ICMP ping to the Gateway Hub overlay IP (10.100.0.1).
#          5. End-to-end access to SaaS Redis (172.29.0.20:6379).
#          6. End-to-end access to Kubernetes NodePort (172.29.0.30:30080).
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY VIRTUAL INTERFACE wg0 & SPOKE IP (10.100.0.10/24)"
echo "WHY: Confirms device wg0 was instantiated in the kernel and assigned 10.100.0.10."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node ip -br addr show dev wg0"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  wg0              UNKNOWN        10.100.0.10/24"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Device Status : "
sudo podman exec baremetal-node ip -br addr show dev wg0 2>/dev/null || echo "FAILED: wg0 interface missing!"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY KERNEL ROUTING TABLE (SPLIT-TUNNEL ENFORCEMENT)"
echo "WHY: Confirms that wg-quick injected specific routes sending 172.29.0.0/16"
echo "     and 10.100.0.0/24 through wg0 while leaving the default gateway on eth0."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node ip route show"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  default via 172.28.0.1 dev eth0"
echo "  10.100.0.0/24 dev wg0 scope link"
echo "  172.28.0.0/16 dev eth0 scope link"
echo "  172.29.0.0/16 dev wg0 scope link"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node ip route show
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY CRYPTOGRAPHIC HANDSHAKE & TRANSFER TELEMETRY"
echo "WHY: Confirms the Noise handshake succeeded with the Gateway Hub and that"
echo "     packets are flowing in both directions (tx > 0, rx > 0)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node wg show wg0"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  endpoint: 172.28.0.2:51820"
echo "  latest handshake: <X seconds or minutes ago>"
echo "  transfer: <X> KiB received, <Y> KiB sent"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec baremetal-node wg show wg0
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY OVERLAY L3 REACHABILITY (PING HUB GATEWAY 10.100.0.1)"
echo "WHY: Validates direct ICMP transit across the encrypted WireGuard overlay."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node ping -c 2 -W 1 10.100.0.1"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  2 packets transmitted, 2 received, 0% packet loss"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Hub Tunnel Ping (10.100.0.1): "
if sudo podman exec baremetal-node ping -c 2 -W 1 10.100.0.1 >/dev/null 2>&1; then
  echo "PASSED (0% packet loss - Tunnel operational)"
else
  echo "FAILED (Unable to ping Hub gateway overlay IP)"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY MANAGED SAAS REDIS ACCESS ACROSS TUNNEL (172.29.0.20:6379)"
echo "WHY: Proves end-to-end L7 database queries cross from Provider B, traverse"
echo "     wg0, are decrypted by the Hub, SNAT'd across eth1, and processed by Redis."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node redis-cli -h 172.29.0.20 ping"
echo "  sudo podman exec baremetal-node redis-cli -h 172.29.0.20 set sre:wireguard:status 'healthy'"
echo "  sudo podman exec baremetal-node redis-cli -h 172.29.0.20 get sre:wireguard:status"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  PING check : PONG"
echo "  SET check  : OK"
echo "  GET check  : healthy"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Redis PING : "
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 ping 2>/dev/null || echo "FAILED"
echo -n "  Redis SET  : "
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 set sre:wireguard:status "healthy" 2>/dev/null || echo "FAILED"
echo -n "  Redis GET  : "
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 get sre:wireguard:status 2>/dev/null || echo "FAILED"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "6. VERIFY KUBERNETES WORKLOAD ACCESS ACROSS TUNNEL (172.29.0.30:30080)"
echo "WHY: Proves HTTP client traffic successfully routes through the overlay and"
echo "     hits the NodePort service on the Kind cluster in Provider A."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node curl --connect-timeout 5 -s http://172.29.0.30:30080"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  HTTP Echo Response: "
K8S_OUT=$(sudo podman exec baremetal-node curl --connect-timeout 5 -s http://172.29.0.30:30080 2>&1 || true)
echo "${K8S_OUT}"
if echo "${K8S_OUT}" | grep -q "HTTP 200 OK"; then
  echo "  STATUS: PASSED (End-to-end Kubernetes access across WireGuard confirmed)"
else
  echo "  STATUS: FAILED"
fi
echo "${SEPARATOR}"
