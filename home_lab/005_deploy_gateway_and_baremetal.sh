#!/usr/bin/env bash
# ==============================================================================
# Script: 005_deploy_gateway_and_baremetal.sh
# Purpose: Deploys the dual-homed WireGuard VPC gateway and the bare-metal spoke
#          node, attaches network interfaces, and installs runtime utilities.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

# Pre-flight check: Ensure prerequisite networks exist
if ! sudo podman network exists provider-a 2>/dev/null || ! sudo podman network exists provider-b 2>/dev/null; then
  echo "ERROR: Required networks 'provider-a' or 'provider-b' are missing."
  echo "Please execute 002_deploy_networks_and_isolation.sh first."
  exit 1
fi

echo "${SEPARATOR}"
echo "STEP 1: LAUNCH DUAL-HOMED VPC GATEWAY ON PROVIDER B (PUBLIC TRANSIT INTERFACE)"
echo "[NOTE]   : Instantiates the gateway container with its primary interface (eth0)"
echo "           on provider-b (172.28.0.2) with packet forwarding enabled."
echo "[CAUSE]  : [PRODUCTION VS LAB UNDERLAY NOTE]: In production, this gateway instance"
echo "           is provisioned inside Provider A's VPC, possessing a private VPC subnet ENI"
echo "           and a public Elastic IP (EIP) managed by an Internet Gateway (IGW)."
echo "           In this local lab, provider-b (172.28.0.0/16) simulates the shared public"
echo "           transit WAN connecting both clouds. The gateway's public-facing WAN leg"
echo "           is bound to 172.28.0.2 so bare-metal nodes can reach it across the simulated WAN."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run -d \\"
echo "    --name vpc-gateway \\"
echo "    --network provider-b \\"
echo "    --ip 172.28.0.2 \\"
echo "    --privileged \\"
echo "    --sysctl net.ipv4.ip_forward=1 \\"
echo "    docker.io/library/alpine:3.20 sleep infinity"
echo ""
echo "[WHY]:"
echo "  - --network provider-b          : Establishes eth0 on the simulated public transit network."
echo "  - --ip 172.28.0.2               : Static public transit endpoint for inbound WireGuard handshakes."
echo "  - --privileged                  : Grants CAP_NET_ADMIN and raw socket capabilities to manage wg0."
echo "  - --sysctl net.ipv4.ip_forward=1: Enables in-kernel packet routing between wg0 and eth1."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Container hash printed; vpc-gateway status: running."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman rm -f vpc-gateway >/dev/null 2>&1 || true

GW_ID=$(sudo podman run -d \
  --name vpc-gateway \
  --network provider-b \
  --ip 172.28.0.2 \
  --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  docker.io/library/alpine:3.20 sleep infinity)

echo "  Gateway Container ID : ${GW_ID}"
echo "  Gateway Status       : $(sudo podman inspect -f '{{.State.Status}}' vpc-gateway 2>/dev/null || echo 'unknown')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: ATTACH GATEWAY'S SECOND INTERFACE TO PROVIDER A (PRIVATE VPC)"
echo "[NOTE]   : Hot-plugs the eth1 interface into provider-a at private IP 172.29.0.2."
echo "[CAUSE]  : Acts as the VPC internal ingress/egress router, bridging decrypted WireGuard"
echo "           tunnel packets directly into Provider A's private subnets."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network connect --ip 172.29.0.2 provider-a vpc-gateway"
echo ""
echo "[WHY]:"
echo "  - Grants the gateway a direct L2/L3 interface (eth1) into the 172.29.0.0/16 VPC."
echo "  - Allows outbound tunnel packets to be SNAT'd via MASQUERADE to 172.29.0.2."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Network interface successfully attached with exit code 0."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network connect --ip 172.29.0.2 provider-a vpc-gateway
echo "  Interface eth1 attached to provider-a."
echo "  VPC Private IP: $(sudo podman inspect vpc-gateway --format '{{.NetworkSettings.Networks.provider-a.IPAddress}}' 2>/dev/null || echo 'unknown')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: LAUNCH BARE-METAL SPOKE NODE ON PROVIDER B"
echo "[NOTE]   : Deploys the simulated bare-metal server on provider-b at 172.28.0.100."
echo "[CAUSE]  : Represents an external, dedicated server residing outside Provider A's cloud."
echo "           [SPLIT-TUNNEL & DNS NOTE]:"
echo "           This node implements a SPLIT-TUNNEL architecture (AllowedIPs = 172.29.0.0/16,"
echo "           10.100.0.0/24). General internet traffic continues to use Provider B's uplink,"
echo "           preventing cloud egress bandwidth charges and gateway bottlenecks."
echo "           In production, Split-DNS (via systemd-resolved routing domains) handles"
echo "           internal VPC domain queries without overriding default public resolvers."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run -d \\"
echo "    --name baremetal-node \\"
echo "    --network provider-b \\"
echo "    --ip 172.28.0.100 \\"
echo "    --privileged \\"
echo "    docker.io/library/alpine:3.20 sleep infinity"
echo ""
echo "[WHY]:"
echo "  - --network provider-b : Isolates the server strictly on the unpeered transit network."
echo "  - --ip 172.28.0.100    : Static public IP representing Bare-Metal Server 01."
echo "  - --privileged         : Allows creation of wg0 and routing table manipulation."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Container hash printed; baremetal-node status: running."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman rm -f baremetal-node >/dev/null 2>&1 || true

BM_ID=$(sudo podman run -d \
  --name baremetal-node \
  --network provider-b \
  --ip 172.28.0.100 \
  --privileged \
  docker.io/library/alpine:3.20 sleep infinity)

echo "  Bare-metal Container ID : ${BM_ID}"
echo "  Bare-metal Status       : $(sudo podman inspect -f '{{.State.Status}}' baremetal-node 2>/dev/null || echo 'unknown')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: INSTALL NETWORKING & VALIDATION UTILITIES IN BOTH CONTAINERS"
echo "[NOTE]   : Updates apk index and installs routing daemons, WireGuard CLI, and test clients."
echo "[CAUSE]  : Minimal Alpine base images lack wireguard-tools, iptables, and client probes."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway apk add --no-cache wireguard-tools iptables iproute2"
echo "  sudo podman exec baremetal-node apk add --no-cache wireguard-tools iptables iproute2 curl redis"
echo ""
echo "[WHY]:"
echo "  - wireguard-tools : Provides 'wg' and 'wg-quick' to establish in-kernel tunnels."
echo "  - iptables        : Enables the gateway to run MASQUERADE / SNAT rules."
echo "  - iproute2        : Provides the 'ip' binary for advanced routing inspection."
echo "  - curl & redis    : Client utilities to test Kubernetes NodePort and Redis services."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Packages installed successfully with exit code 0 on both nodes."
echo ""
echo "[ACTUAL OUTPUT]:"
echo "  Installing packages on vpc-gateway..."
sudo podman exec vpc-gateway apk add --no-cache wireguard-tools iptables iproute2 >/dev/null
echo "  vpc-gateway packages installed successfully."

echo "  Installing packages on baremetal-node..."
sudo podman exec baremetal-node apk add --no-cache wireguard-tools iptables iproute2 curl redis >/dev/null
echo "  baremetal-node packages installed successfully."
echo "${SEPARATOR}"
