#!/usr/bin/env bash
# ==============================================================================
# Script: 002_verify_networks_and_isolation.sh
# Purpose: Step-by-step verification of environment reset, Podman Netavark bridges,
#          and kernel-level isolation rules with full command audit visibility.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY CONTAINER & KIND CLUSTER CLEANUP"
echo "WHY: Podman and Kind manage persistent network namespaces and IP allocations."
echo "     Lingering containers cause static IP collision errors during setup."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman ps -a --filter 'name=baremetal-node|vpc-gateway|saas-redis|provider-a-k8s|test-isolation-target' --format '{{.Names}}: {{.Status}}'"
echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Containers : (clean - zero matching containers)"
echo "  Kind       : (clean - provider-a-k8s not present)"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Containers : "
LEFTOVER_CONTAINERS=$(sudo podman ps -a --filter "name=baremetal-node|vpc-gateway|saas-redis|provider-a-k8s|test-isolation-target" --format "{{.Names}}: {{.Status}}" 2>/dev/null || true)
if [ -z "${LEFTOVER_CONTAINERS}" ]; then
  echo "(clean - zero matching containers)"
else
  echo "WARNING: Lingering containers detected:"
  echo "${LEFTOVER_CONTAINERS}"
fi

echo -n "  Kind       : "
if sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters 2>&1 | grep -q "provider-a-k8s"; then
  echo "provider-a-k8s found (WARNING: Not cleaned!)"
else
  echo "(clean - provider-a-k8s not present)"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY PODMAN NETWORK REGISTRATION & DRIVERS"
echo "WHY: Confirms Podman's Netavark stack registered both logical networks"
echo "     under the standard isolated 'bridge' driver."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network ls --filter 'name=provider'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  NETWORK ID    NAME          DRIVER"
echo "  <hash>        provider-a    bridge"
echo "  <hash>        provider-b    bridge"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network ls --filter "name=provider"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY IPAM SUBNETS, GATEWAYS, AND NETAVARK INTERFACES"
echo "WHY: Netavark dynamically assigns host network devices (podman0, podman1, etc.)."
echo "     Querying {{.NetworkInterface}} confirms that provider-a has CIDR 172.29.0.0/16"
echo "     and provider-b has CIDR 172.28.0.0/16 mapped to their respective devices."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network inspect provider-a provider-b \\"
echo "    --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Interface={{.NetworkInterface}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Interface=podmanX (e.g. podman1)"
echo "  provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Interface=podmanY (e.g. podman0)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network inspect provider-a provider-b \
  --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Interface={{.NetworkInterface}}'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY LINUX HOST KERNEL BRIDGE DEVICES & GATEWAY IPS"
echo "WHY: Verifies that the Linux host kernel instantiated the actual Netavark bridge"
echo "     interfaces reported in Step 3 and assigned the expected .1 gateway IPs."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  IFACE_A=\$(sudo podman network inspect provider-a --format '{{.NetworkInterface}}')"
echo "  IFACE_B=\$(sudo podman network inspect provider-b --format '{{.NetworkInterface}}')"
echo "  ip -br addr show \"\$IFACE_A\" \"\$IFACE_B\""
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  podmanX    UP/UNKNOWN/DOWN    172.29.0.1/16 ..."
echo "  podmanY    UP/UNKNOWN/DOWN    172.28.0.1/16 ..."
echo ""
echo "[ACTUAL OUTPUT]:"
IFACE_A=$(sudo podman network inspect provider-a --format '{{.NetworkInterface}}' 2>/dev/null || echo "")
IFACE_B=$(sudo podman network inspect provider-b --format '{{.NetworkInterface}}' 2>/dev/null || echo "")

printf "  - Provider A Netavark Device : %s\n" "${IFACE_A:-NOT SET}"
printf "  - Provider B Netavark Device : %s\n" "${IFACE_B:-NOT SET}"

FOUND_COUNT=0
for iface in "${IFACE_A}" "${IFACE_B}"; do
  if [ -n "${iface}" ] && ip link show "${iface}" >/dev/null 2>&1; then
    ip -br addr show "${iface}"
    FOUND_COUNT=$((FOUND_COUNT + 1))
  fi
done

if [ "$FOUND_COUNT" -lt 2 ]; then
  echo "  Note: Netavark lazily initializes kernel interfaces upon first container connection."
  echo "  Host addresses currently bound to provider subnets:"
  ip -br addr show | grep -E '(172\.28\.0\.1|172\.29\.0\.1)' || echo "  (Pending active container attachment)"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY IPTABLES ISOLATION DROP RULES IN FORWARD CHAIN"
echo "WHY: Prevents host kernel routing between the two subnets (net.ipv4.ip_forward)."
echo "     Rules #1 and #2 must be explicit DROP rules intercepting all cross-traffic."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo iptables -nvL FORWARD --line-numbers | head -n 7"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Chain FORWARD (policy ACCEPT ...)"
echo "  num   pkts bytes target     prot opt in     out     source               destination"
echo "  1     ...  ...   DROP       all  --  *      *       172.28.0.0/16        172.29.0.0/16"
echo "  2     ...  ...   DROP       all  --  *      *       172.29.0.0/16        172.28.0.0/16"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo iptables -nvL FORWARD --line-numbers | head -n 7
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "6. ACTIVE PACKET DROP & ISOLATION TEST (LIVE PING TRAFFIC)"
echo "WHY: Confirms the firewall actively intercepts cross-bridge packets in runtime"
echo "     and ensures the iptables DROP counter increments on rule #1."
echo "${SUB_SEPARATOR}"
echo "[COMMANDS EXECUTED]:"
echo "  1. sudo podman run -d --rm --name test-isolation-target --network provider-a --ip 172.29.0.254 docker.io/library/alpine:3.20 sleep 60"
echo "  2. sudo podman run --rm --network provider-b --ip 172.28.0.254 docker.io/library/alpine:3.20 ping -c 2 -W 1 172.29.0.254"
echo "  3. sudo iptables -nvL FORWARD --line-numbers | head -n 3"
echo "  4. sudo podman rm -f test-isolation-target"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Ping Result     : 100% packet loss (2 packets transmitted, 0 received)"
echo "  iptables Rule 1 : pkts >= 2, bytes > 0"
echo ""
echo "[ACTUAL OUTPUT]:"

# A. Clean prior test container if lingering and start target listener in provider-a
sudo podman rm -f test-isolation-target >/dev/null 2>&1 || true
sudo podman run -d --rm --name test-isolation-target --network provider-a --ip 172.29.0.254 docker.io/library/alpine:3.20 sleep 60 >/dev/null

# B. Attempt cross-bridge ping from provider-b
echo -n "  Running cross-bridge ping test: "
PING_OUTPUT=$(sudo podman run --rm --network provider-b --ip 172.28.0.254 docker.io/library/alpine:3.20 ping -c 2 -W 1 172.29.0.254 2>&1 || true)
if echo "${PING_OUTPUT}" | grep -q "100% packet loss"; then
  echo "PASSED (100% packet loss detected)"
else
  echo "FAILED (Packets were not dropped! Check iptables FORWARD chain)"
fi

# C. Inspect dropped packet counter using standard iptables listing
echo "  Inspecting iptables DROP rule counter (Chain FORWARD, Rule 1):"
sudo iptables -nvL FORWARD --line-numbers | head -n 3

# D. Cleanup target container
sudo podman rm -f test-isolation-target >/dev/null 2>&1 || true
echo "${SEPARATOR}"
