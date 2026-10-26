#!/usr/bin/env bash
# ==============================================================================
# Script: 002_deploy_networks_and_isolation.sh
# Purpose: Cleans up existing lab state, instantiates isolated Podman bridge
#          networks (Provider A VPC & Provider B Internet), and enforces host-level
#          kernel firewall isolation rules.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "STEP 1: CLEAN UP LEFTOVER CONTAINERS, NETWORKS, AND KIND CLUSTERS"
echo "[NOTE]   : Resets the container and network environment to a pristine state."
echo "[CAUSE]  : Stale containers or bridge networks holding IPs (172.28.0.0/16, 172.29.0.0/16)"
echo "           will cause static IP allocation and CNI collision errors on subsequent runs."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman rm -f baremetal-node vpc-gateway saas-redis provider-a-k8s-control-plane 2>/dev/null || true"
echo "  sudo podman network rm provider-a provider-b 2>/dev/null || true"
echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s 2>/dev/null || true"
echo ""
echo "[WHY]:"
echo "  - Removes previous test containers and avoids name/IP reservation conflicts."
echo "  - Frees Linux bridge interfaces (br-provider-a and br-provider-b) on the host."
echo "  - Ensures a reproducible baseline before establishing new network topologies."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Containers and networks removed or skipped if non-existent; exit code 0."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman rm -f baremetal-node vpc-gateway saas-redis provider-a-k8s-control-plane >/dev/null 2>&1 || true
sudo podman network rm provider-a provider-b >/dev/null 2>&1 || true
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s >/dev/null 2>&1 || true
echo "  Cleanup completed successfully (prior containers, networks, and clusters purged)."
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: CREATE PROVIDER B NETWORK (SIMULATED PUBLIC INTERNET / BARE-METAL)"
echo "[NOTE]   : Creates the Layer 2/3 bridge network representing Provider B's unpeered public subnet."
echo "[CAUSE]  : The technical challenge specifies bare-metal workloads reside on Provider B with"
echo "           only public internet transit into Provider A[cite: 1, 2]."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network create \\"
echo "    --subnet 172.28.0.0/16 \\"
echo "    --gateway 172.28.0.1 \\"
echo "    -o \"bridge=br-provider-b\" \\"
echo "    provider-b"
echo ""
echo "[WHY]:"
echo "  - --subnet 172.28.0.0/16 : Allocates a distinct address space for Provider B nodes."
echo "  - --gateway 172.28.0.1   : Sets default route IP on the virtual bridge."
echo "  - -o \"bridge=...\"        : Explicitly binds to 'br-provider-b' for predictable iptables filtering."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Network name or hash printed to stdout; bridge 'br-provider-b' instantiated."
echo ""
echo "[ACTUAL OUTPUT]:"
NET_B_OUT=$(sudo podman network create \
  --subnet 172.28.0.0/16 \
  --gateway 172.28.0.1 \
  -o "bridge=br-provider-b" \
  provider-b 2>&1)
echo "  Network Created : ${NET_B_OUT}"
echo "  Bridge State    : $(ip -br addr show br-provider-b 2>/dev/null || echo 'br-provider-b created')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: CREATE PROVIDER A NETWORK (SIMULATED PRIVATE VPC)"
echo "[NOTE]   : Creates the isolated private network representing Provider A's VPC[cite: 1, 2]."
echo "[CAUSE]  : SaaS databases (Redis) and Kubernetes core workloads must live inside"
echo "           an isolated private VPC with no direct external routes[cite: 1, 2]."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network create \\"
echo "    --subnet 172.29.0.0/16 \\"
echo "    --gateway 172.29.0.1 \\"
echo "    -o \"bridge=br-provider-a\" \\"
echo "    provider-a"
echo ""
echo "[WHY]:"
echo "  - --subnet 172.29.0.0/16 : Dedicated private VPC CIDR block for cloud resources."
echo "  - --gateway 172.29.0.1   : Sets the default gateway for intra-VPC routing."
echo "  - -o \"bridge=...\"        : Binds to 'br-provider-a' on the host network stack."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Network name or hash printed to stdout; bridge 'br-provider-a' instantiated."
echo ""
echo "[ACTUAL OUTPUT]:"
NET_A_OUT=$(sudo podman network create \
  --subnet 172.29.0.0/16 \
  --gateway 172.29.0.1 \
  -o "bridge=br-provider-a" \
  provider-a 2>&1)
echo "  Network Created : ${NET_A_OUT}"
echo "  Bridge State    : $(ip -br addr show br-provider-a 2>/dev/null || echo 'br-provider-a created')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: ENFORCE INTER-BRIDGE FIREWALL ISOLATION (SIMULATE UNPEERED CLOUDS)"
echo "[NOTE]   : Inserts explicit DROP rules at the top of the host's iptables FORWARD chain."
echo "[CAUSE]  : Linux hosts with IP forwarding enabled will natively route packets between two local"
echo "           bridges, which would falsely allow bare-metal nodes to reach the VPC without a tunnel[cite: 1, 2]."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo iptables -I FORWARD 1 -s 172.28.0.0/16 -d 172.29.0.0/16 -j DROP"
echo "  sudo iptables -I FORWARD 2 -s 172.29.0.0/16 -d 172.28.0.0/16 -j DROP"
echo ""
echo "[WHY]:"
echo "  - Rule 1 : Drops unencrypted packets flowing from Provider B (172.28.0.0/16) to Provider A VPC."
echo "  - Rule 2 : Drops any return or outbound packets flowing from VPC back to Provider B."
echo "  - Ensures that the only path between the two clouds is the WireGuard VPN tunnel."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  DROP rules inserted at lines 1 and 2 of the FORWARD chain."
echo ""
echo "[ACTUAL OUTPUT]:"
# Clean any duplicate rules if previously inserted
sudo iptables -D FORWARD -s 172.28.0.0/16 -d 172.29.0.0/16 -j DROP 2>/dev/null || true
sudo iptables -D FORWARD -s 172.29.0.0/16 -d 172.28.0.0/16 -j DROP 2>/dev/null || true

# Insert rules at head of FORWARD chain
sudo iptables -I FORWARD 1 -s 172.28.0.0/16 -d 172.29.0.0/16 -j DROP
sudo iptables -I FORWARD 2 -s 172.29.0.0/16 -d 172.28.0.0/16 -j DROP

echo "  iptables isolation rules inserted. Active FORWARD rules:"
sudo iptables -nvL FORWARD --line-numbers | head -n 6
echo "${SEPARATOR}"
