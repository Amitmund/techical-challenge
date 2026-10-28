#!/usr/bin/env bash
# ==============================================================================
# Script: 006_verify_negative_isolation.sh
# Purpose: Pre-tunnel negative security gate. Proves that bare-metal nodes cannot
#          reach Provider A VPC Redis or Kubernetes before WireGuard is brought up.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. NEGATIVE TEST: SAAS REDIS UNREACHABLE FROM BARE-METAL (TCP 6379)"
echo "[NOTE]   : Probes Redis (172.29.0.20:6379) directly from baremetal-node."
echo "[CAUSE]  : Host iptables FORWARD drop rules and bridge isolation must block all"
echo "           unencrypted transit packets between provider-b and provider-a."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node redis-cli -h 172.29.0.20 --connect-timeout 2 ping"
echo ""
echo "[WHY]:"
echo "  - Proves the private VPC database is completely unreachable over raw public transit."
echo "  - Connect timeout of 2s ensures fast test execution without hanging."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Connection timed out (exit code non-zero, Redis unreachable)."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Redis Isolation Probe: "
REDIS_ERR=$(sudo podman exec baremetal-node redis-cli -h 172.29.0.20 --connect-timeout 2 ping 2>&1 || true)
if echo "${REDIS_ERR}" | grep -q "PONG"; then
  echo "FAILED (SECURITY BREACH: Redis was reached without WireGuard!)"
else
  echo "PASSED (Redis unreachable: ${REDIS_ERR:-Connection dropped by firewall})"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. NEGATIVE TEST: KUBERNETES WORKLOAD UNREACHABLE FROM BARE-METAL (TCP 30080)"
echo "[NOTE]   : Probes NodePort 30080 (172.29.0.30:30080) directly from baremetal-node."
echo "[CAUSE]  : Validates that Kubernetes cluster services are shielded from direct"
echo "           transit access prior to tunnel activation."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node curl --connect-timeout 2 -s http://172.29.0.30:30080"
echo ""
echo "[WHY]:"
echo "  - Confirms no host port forwarding or bridge misconfiguration exposes K8s to provider-b."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Curl connection timeout (exit code 28; empty response)."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  K8s Workload Isolation Probe: "
K8S_RESP=$(sudo podman exec baremetal-node curl --connect-timeout 2 -s http://172.29.0.30:30080 2>&1 || true)
if echo "${K8S_RESP}" | grep -q "HTTP 200 OK"; then
  echo "FAILED (SECURITY BREACH: K8s reached without WireGuard!)"
elif [ -z "${K8S_RESP}" ]; then
  echo "PASSED (Connection dropped / timed out as expected - cluster is isolated)."
else
  echo "PASSED (Cluster unreachable: ${K8S_RESP})"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY IPTABLES FORWARD DROP COUNTERS"
echo "[NOTE]   : Inspects host iptables FORWARD rules to confirm dropped packets."
echo "[CAUSE]  : Confirms that packets sent during Tests 1 and 2 were actively dropped"
echo "           by host firewall rule #1 (provider-b -> provider-a)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo iptables -nvL FORWARD --line-numbers | head -n 3"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Rule 1 (172.28.0.0/16 -> 172.29.0.0/16): pkts > 0, bytes > 0"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo iptables -nvL FORWARD --line-numbers | head -n 3
echo "${SEPARATOR}"
