#!/usr/bin/env bash
# ==============================================================================
# Verification Script: Network Isolation & Environment Reset Validation
# ==============================================================================

echo "=============================================================================="
echo "1. VERIFY CONTAINER & KIND CLUSTER CLEANUP"
echo "WHY: Podman and Kind manage persistent network namespaces and IP allocations."
echo "     Lingering containers cause static IP collision errors during setup."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  Container check : (Empty output - zero matching containers)"
echo "  Kind check      : No kind clusters found. (or no cluster named provider-a-k8s)"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Containers : "
sudo podman ps -a --filter "name=baremetal-node|vpc-gateway|saas-redis|provider-a-k8s" --format "{{.Names}}: {{.Status}}" || true
echo "  Kind       : "
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters 2>&1 | grep "provider-a-k8s" || echo "  (provider-a-k8s not found - clean)"
echo "=============================================================================="
echo ""


echo "=============================================================================="
echo "2. VERIFY PODMAN NETWORK REGISTRATION & DRIVERS"
echo "WHY: Confirms Podman's Netavark/CNI stack registered both logical networks"
echo "     under the standard isolated 'bridge' driver."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  NETWORK ID    NAME          DRIVER"
echo "  <hash>        provider-a    bridge"
echo "  <hash>        provider-b    bridge"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network ls --filter "name=provider"
echo "=============================================================================="
echo ""


echo "=============================================================================="
echo "3. VERIFY IPAM SUBNETS, GATEWAYS, AND BRIDGE BINDINGS"
echo "WHY: Guarantees provider-a holds the private VPC CIDR (172.29.0.0/16) and"
echo "     provider-b holds the transit CIDR (172.28.0.0/16), each bound to their"
echo "     explicitly named host Linux bridge devices."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Bridge=br-provider-a"
echo "  provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Bridge=br-provider-b"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network inspect provider-a provider-b \
  --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Bridge={{index .Options "bridge"}}'
echo "=============================================================================="
echo ""


echo "=============================================================================="
echo "4. VERIFY LINUX HOST KERNEL BRIDGE DEVICES"
echo "WHY: Confirms that the Linux host kernel instantiated the actual virtual switch"
echo "     interfaces (br-provider-a, br-provider-b) and bound the .1 gateway IPs."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  br-provider-a    UP/DOWN    172.29.0.1/16 ..."
echo "  br-provider-b    UP/DOWN    172.28.0.1/16 ..."
echo ""
echo "[ACTUAL OUTPUT]:"
ip -br addr show br-provider-a br-provider-b
echo "=============================================================================="
echo ""


echo "=============================================================================="
echo "5. VERIFY IPTABLES ISOLATION DROP RULES IN FORWARD CHAIN"
echo "WHY: Prevents host kernel routing between the two bridges (net.ipv4.ip_forward)."
echo "     Rules #1 and #2 must be DROP rules matching cross-traffic between subnets."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)"
echo "  num   pkts bytes target     prot opt in     out     source               destination"
echo "  1        0     0 DROP       all  --  *      *       172.28.0.0/16        172.29.0.0/16"
echo "  2        0     0 DROP       all  --  *      *       172.29.0.0/16        172.28.0.0/16"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo iptables -nvL FORWARD --line-numbers | head -n 7
echo "=============================================================================="
echo ""


echo "=============================================================================="
echo "6. ACTIVE PACKET DROP & ISOLATION TEST"
echo "WHY: Verifies the firewall actively drops packets in practice and confirms the"
echo "     iptables packet drop counter increments under real cross-bridge traffic."
echo "------------------------------------------------------------------------------"
echo "[EXPECTED OUTPUT]:"
echo "  Ping Result     : 100% packet loss (2 packets transmitted, 0 received)"
echo "  iptables Rule 1 : pkts >= 2, bytes > 0"
echo ""
echo "[ACTUAL OUTPUT]:"

# A. Start temporary target listener container in provider-a
sudo podman run -d --rm --name test-isolation-target --network provider-a --ip 172.29.0.254 docker.io/library/alpine:3.20 sleep 30 >/dev/null

# B. Attempt cross-bridge ping from provider-b
echo -n "  Running Ping from provider-b -> provider-a: "
PING_OUTPUT=$(sudo podman run --rm --network provider-b --ip 172.28.0.254 docker.io/library/alpine:3.20 ping -c 2 -W 1 172.29.0.254 2>&1 || true)
if echo "${PING_OUTPUT}" | grep -q "100% packet loss"; then
  echo "PASSED (100% packet loss detected)"
else
  echo "FAILED (Packets were not dropped!)"
fi

# C. Inspect dropped packet counter
echo "  Checking iptables DROP counter:"
sudo iptables -nvL FORWARD 1

# D. Cleanup target container
sudo podman rm -f test-isolation-target >/dev/null 2>&1 || true
echo "=============================================================================="
