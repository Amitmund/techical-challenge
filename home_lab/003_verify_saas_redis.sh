#!/usr/bin/env bash
# ==============================================================================
# Script: 003_verify_saas_redis.sh
# Purpose: Comprehensive validation of Redis container lifecycle, IPAM binding,
#          zero host port publication, internal listener, kernel bridge activation,
#          and intra-VPC reachability.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY CONTAINER RUNTIME STATUS"
echo "WHY: Confirms the container engine initialized the process and the database"
echo "     daemon did not exit or crash on startup."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman ps --filter 'name=saas-redis' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  NAMES         STATUS        IMAGE"
echo "  saas-redis    Up ...        docker.io/library/redis:7-alpine"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman ps --filter "name=saas-redis" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY IPAM NETWORK ATTACHMENT & STATIC IP"
echo "WHY: Validates that the container is bound exclusively to the private VPC"
echo "     network ('provider-a') and possesses the designated IP (172.29.0.20)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman inspect saas-redis \\"
echo "    --format 'Network={{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} (IP={{.IPAddress}} Gateway={{.Gateway}}){{end}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Network=provider-a (IP=172.29.0.20 Gateway=172.29.0.1)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman inspect saas-redis \
  --format 'Network={{range $k, $v := .NetworkSettings.Networks}}{{$k}} (IP={{.IPAddress}} Gateway={{.Gateway}}){{end}}'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY ZERO HOST PORTS PUBLISHED (STRICT PRIVATE ISOLATION)"
echo "WHY: Simulates a cloud-managed SaaS database accessible exclusively via VPC."
echo "     Confirming no ports are mapped to the host ensures no external bypass."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman port saas-redis"
echo "  sudo podman inspect saas-redis --format '{{.NetworkSettings.Ports}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Port mappings : (None - strictly private)"
echo "  Inspect Ports : map[]"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Port mappings : "
PORT_MAPPINGS=$(sudo podman port saas-redis 2>&1 || true)
if [ -z "${PORT_MAPPINGS}" ]; then
  echo "(None - strictly private)"
else
  echo "WARNING: Ports exposed: ${PORT_MAPPINGS}"
fi
echo -n "  Inspect Ports : "
sudo podman inspect saas-redis --format '{{.NetworkSettings.Ports}}'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY NETAVARK KERNEL BRIDGE MATERIALIZATION"
echo "WHY: Proves that attaching saas-redis triggered Netavark to instantiate"
echo "     the virtual bridge in the host kernel and bind gateway 172.29.0.1."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  IFACE_A=\$(sudo podman network inspect provider-a --format '{{.NetworkInterface}}')"
echo "  ip -br addr show \"\$IFACE_A\""
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  podmanX    UP/UNKNOWN    172.29.0.1/16 ..."
echo ""
echo "[ACTUAL OUTPUT]:"
IFACE_A=$(sudo podman network inspect provider-a --format '{{.NetworkInterface}}' 2>/dev/null || echo "")
if [ -n "${IFACE_A}" ] && ip link show "${IFACE_A}" >/dev/null 2>&1; then
  echo -n "  Netavark Bridge (${IFACE_A}) : "
  ip -br addr show "${IFACE_A}"
else
  echo "  Kernel bridge interface not detected on host stack!"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY INTERNAL PORT LISTENER INSIDE CONTAINER"
echo "WHY: Checks that Redis is actively bound and listening on TCP port 6379"
echo "     inside its own network namespace."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec saas-redis sh -c 'netstat -tlpn 2>/dev/null || ss -tlpn 2>/dev/null || redis-cli ping'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  tcp ... 0.0.0.0:6379 ... LISTEN (or PONG)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec saas-redis sh -c 'netstat -tlpn 2>/dev/null || ss -tlpn 2>/dev/null || redis-cli ping'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "6. FUNCTIONAL INTRA-VPC PING & COMMAND TEST"
echo "WHY: Launches an ephemeral container directly inside provider-a to"
echo "     prove that workloads within the VPC can connect and execute Redis commands."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 ping"
echo "  sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 set test:init 'ok'"
echo "  sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 get test:init"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  PING check : PONG"
echo "  SET check  : OK"
echo "  GET check  : ok"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  PING check : "
sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 ping 2>/dev/null || echo "FAILED"
echo -n "  SET check  : "
sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 set test:init 'ok' 2>/dev/null || echo "FAILED"
echo -n "  GET check  : "
sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 get test:init 2>/dev/null || echo "FAILED"
echo "${SEPARATOR}"
