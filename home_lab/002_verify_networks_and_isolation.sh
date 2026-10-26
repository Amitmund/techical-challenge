#!/usr/bin/env bash
# ==============================================================================
# Script: 002_verify_networks_and_isolation.sh
# Purpose: Step-by-step verification of environment reset, Podman virtual bridges,
#          and kernel-level isolation rules with full command audit visibility.
# ==============================================================================

set -uo pipefail

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY CONTAINER & KIND CLUSTER CLEANUP"
echo "WHY: Podman and Kind manage persistent network namespaces and IP allocations."
echo "     Lingering containers cause static IP collision errors during setup."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman ps -a --filter 'name=baremetal-node|vpc-gateway|saas-redis|provider-a-k8s' --format '{{.Names}}: {{.Status}}'"
echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Containers : (Empty output - zero matching containers)"
echo "  Kind       : (provider-a-k8s not listed / 'No kind clusters found.')"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Containers : "
sudo podman ps -a --filter "name=baremetal-node|vpc-gateway|saas-redis|provider-a-k8s" --format "{{.Names}}: {{.Status}}" || true
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
echo "WHY: Confirms Podman's Netavark/CNI stack registered both logical networks"
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
echo "3. VERIFY IPAM SUBNETS, GATEWAYS, AND BRIDGE BINDINGS"
echo "WHY: Guarantees provider-a holds the private VPC CIDR (172.29.0.0/16) and"
echo "     provider-b holds the transit CIDR (172.28.0.0/16), each bound to their"
echo "     explicitly named host Linux bridge devices."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network inspect provider-a provider-b \\"
echo "    --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Bridge={{index .Options \"bridge\"}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Bridge=br-provider-a"
echo "  provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Bridge=br-provider-b"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network inspect provider-a provider-b \
  --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Bridge={{index .Options "bridge"}}'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY LINUX HOST KERNEL BRIDGE DEVICES"
echo "WHY: Confirms that the Linux host kernel instantiated the actual virtual switch"
echo "     interfaces (br-provider-a, br-provider-b) and bound the .1 gateway IPs."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  ip -br addr show br-provider-a br-provider-b"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  br-provider-a    UP/DOWN    172.29.0.1/16 ..."
echo "  br-provider-b    UP/DOWN    172.28.0.1/16 ..."
echo ""
echo "[ACTUAL OUTPUT]:"
ip -br addr show br-provider-a br-provider-b
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY IPTABLES ISOLATION DROP RULES IN FORWARD CHAIN"
echo "WHY: Prevents host kernel routing between the two bridges (net.ipv4.ip_forward)."
echo "     Rules #1 and #2 must be explicit DROP rules intercepting all cross-traffic."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo iptables -nvL FORWARD --line-numbers | head -n 7"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)"
echo "  num   pkts bytes target     prot opt in     out     source               destination"
echo "  1        0     0 DROP       all  --  *      *       172.28.0.0/16        172.29.0.0/16"
echo "  2        0     0 DROP       all  --  *      *       172.29.0.0/16        172.28.0.0/16"
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
echo "  1. sudo podman run -d --rm --name test-isolation-target --network provider-a --ip 172.29.0.254 docker.io/library/alpine:3.20 sleep 30"
echo "  2. sudo podman run --rm --network provider-b --ip 172.28.0.254 docker.io/library/alpine:3.20 ping -c 2 -W 1 172.29.0.254"
echo "  3. sudo iptables -nvL FORWARD 1"
echo "  4. sudo podman rm -f test-isolation-target"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Ping Result     : 100% packet loss (2 packets transmitted, 0 received)"
echo "  iptables Rule 1 : pkts >= 2, bytes > 0"
echo ""
echo "[ACTUAL OUTPUT]:"

# A. Start temporary target listener container in provider-a
sudo podman run -d --rm --name test-isolation-target --network provider-a --ip 172.29.0.254 docker.io/library/alpine:3.20 sleep 30 >/dev/null

# B. Attempt cross-bridge ping from provider-b
echo -n "  Running cross-bridge ping test: "
PING_OUTPUT=$(sudo podman run --rm --network provider-b --ip 172.28.0.254 docker.io/library/alpine:3.20 ping -c 2 -W 1 172.29.0.254 2>&1 || true)
if echo "${PING_OUTPUT}" | grep -q "100% packet loss"; then
  echo "PASSED (100% packet loss detected)"
else
  echo "FAILED (Packets were not dropped!)"
fi

# C. Inspect dropped packet counter
echo "  Inspecting iptables DROP rule counter:"
sudo iptables -nvL FORWARD 1

# D. Cleanup target container
sudo podman rm -f test-isolation-target >/dev/null 2>&1 || true
echo "${SEPARATOR}"
