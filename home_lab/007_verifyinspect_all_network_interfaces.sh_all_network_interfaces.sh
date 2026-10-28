#!/usr/bin/env bash
# ==============================================================================
# Script: inspect_all_network_interfaces.sh
# Purpose: Comprehensive audit of all host kernel interfaces, Podman Netavark
#          bridges, container network namespaces, IP allocations, and routing tables.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. AUDIT HOST KERNEL NETWORK INTERFACES & ADDRESSES"
echo "[NOTE]   : Queries the Ubuntu host's root network namespace using iproute2."
echo "[CAUSE]  : Identifies active physical uplinks, virtual Netavark bridges,"
echo "           and veth endpoints created by the container engine."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  ip -br addr show"
echo ""
echo "[WHY]:"
echo "  - Confirms host bridge instantiation for provider-a and provider-b."
echo "  - Verifies host gateway IPs (172.28.0.1 and 172.29.0.1) are actively bound."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  lo               UNKNOWN        127.0.0.1/8 ::1/128"
echo "  <uplink>         UP             <host-lan-ip>/..."
echo "  podmanX          UP/UNKNOWN     172.28.0.1/16 ..."
echo "  podmanY          UP/UNKNOWN     172.29.0.1/16 ..."
echo ""
echo "[ACTUAL OUTPUT]:"
ip -br addr show
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. AUDIT PODMAN LOGICAL NETWORKS & NETAVARK DEVICE MAPPINGS"
echo "[NOTE]   : Inspects Podman's network configuration database."
echo "[CAUSE]  : Correlates logical network names (provider-a, provider-b) to"
echo "           dynamically allocated Linux kernel devices (podman0, podman1, etc.)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network inspect provider-a provider-b \\"
echo "    --format 'table {{.Name}}\t{{.NetworkInterface}}\t{{(index .Subnets 0).Subnet}}\t{{(index .Subnets 0).Gateway}}'"
echo ""
echo "[WHY]:"
echo "  - Ensures no CIDR drift or gateway misconfiguration exists in Netavark IPAM."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  NAME          INTERFACE     SUBNET           GATEWAY"
echo "  provider-a    podmanX       172.29.0.0/16    172.29.0.1"
echo "  provider-b    podmanY       172.28.0.0/16    172.28.0.1"
echo ""
echo "[ACTUAL OUTPUT]:"
if sudo podman network exists provider-a 2>/dev/null && sudo podman network exists provider-b 2>/dev/null; then
  printf "  %-14s %-12s %-18s %-14s\n" "NAME" "INTERFACE" "SUBNET" "GATEWAY"
  printf "  %-14s %-12s %-18s %-14s\n" "----" "---------" "------" "-------"
  for net in provider-a provider-b; do
    IFACE=$(sudo podman network inspect "$net" --format '{{.NetworkInterface}}' 2>/dev/null || echo "n/a")
    SUBNET=$(sudo podman network inspect "$net" --format '{{(index .Subnets 0).Subnet}}' 2>/dev/null || echo "n/a")
    GW=$(sudo podman network inspect "$net" --format '{{(index .Subnets 0).Gateway}}' 2>/dev/null || echo "n/a")
    printf "  %-14s %-12s %-18s %-14s\n" "$net" "$IFACE" "$SUBNET" "$GW"
  done
else
  echo "  WARNING: provider-a or provider-b networks do not exist yet."
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. AUDIT CONTAINER NETWORK INTERFACES (NAMESPACES)"
echo "[NOTE]   : Enters each running container namespace to query local interfaces."
echo "[CAUSE]  : Verifies interface assignment, static IP binding, MAC addresses, and MTUs."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec <container> ip -br addr show"
echo ""
echo "[WHY]:"
echo "  - vpc-gateway: Must be dual-homed with eth0 (172.28.0.2) and eth1 (172.29.0.2)."
echo "  - baremetal-node: Single-homed with eth0 (172.28.0.100)."
echo "  - saas-redis: Single-homed with eth0 (172.29.0.20)."
echo "  - provider-a-k8s-control-plane: Dual-homed (kind bridge + eth1: 172.29.0.30)."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Each container outputs active virtual interfaces with correct IP/CIDR blocks."
echo ""
echo "[ACTUAL OUTPUT]:"
CONTAINERS=("vpc-gateway" "baremetal-node" "saas-redis" "provider-a-k8s-control-plane")

for c in "${CONTAINERS[@]}"; do
  echo "  >>> Container: ${c}"
  if sudo podman ps -q --filter "name=^${c}$" | grep -q .; then
    sudo podman exec "$c" ip -br addr show 2>/dev/null | sed 's/^/      /' || echo "      (Failed to query interfaces)"
  else
    echo "      [STATUS: Container not running / not created]"
  fi
  echo ""
done
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. AUDIT CONTAINER ROUTING TABLES"
echo "[NOTE]   : Dumps kernel L3 routing tables for the gateway and bare-metal nodes."
echo "[CAUSE]  : Confirms default routes point to the proper Netavark bridge gateways"
echo "           and prepares for upcoming WireGuard overlay route verification."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway ip route show"
echo "  sudo podman exec baremetal-node ip route show"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Kernel routing tables showing connected subnets and default gateways."
echo ""
echo "[ACTUAL OUTPUT]:"
for c in "vpc-gateway" "baremetal-node"; do
  echo "  >>> Routing Table: ${c}"
  if sudo podman ps -q --filter "name=^${c}$" | grep -q .; then
    sudo podman exec "$c" ip route show 2>/dev/null | sed 's/^/      /' || echo "      (ip route command failed)"
  else
    echo "      [STATUS: Container not running]"
  fi
  echo ""
done
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. CONSOLIDATED TOPOLOGY INTERFACE MAPPING TABLE"
echo "[NOTE]   : Aggregates runtime data into a unified cross-cloud topology map."
echo "[CAUSE]  : Provides instant, single-pane-of-glass verification of the network layout."
echo "${SUB_SEPARATOR}"
printf "  %-30s %-12s %-18s %-20s\n" "NODE / CONTAINER" "INTERFACE" "IPV4 ADDRESS" "NETWORK SEGMENT"
printf "  %-30s %-12s %-18s %-20s\n" "------------------------------" "------------" "------------------" "--------------------"

# Host Netavark bridges
IFACE_B=$(sudo podman network inspect provider-b --format '{{.NetworkInterface}}' 2>/dev/null || echo "n/a")
IFACE_A=$(sudo podman network inspect provider-a --format '{{.NetworkInterface}}' 2>/dev/null || echo "n/a")
printf "  %-30s %-12s %-18s %-20s\n" "host (Ubuntu Netavark)" "${IFACE_B}" "172.28.0.1/16" "provider-b (Transit)"
printf "  %-30s %-12s %-18s %-20s\n" "host (Ubuntu Netavark)" "${IFACE_A}" "172.29.0.1/16" "provider-a (VPC)"

# Container interface extractor
for c in "${CONTAINERS[@]}"; do
  if sudo podman ps -q --filter "name=^${c}$" | grep -q .; then
    # Parse interfaces and addresses inside container
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      dev=$(echo "$line" | awk '{print $1}')
      ips=$(echo "$line" | awk '{$1=$2=""; print $0}' | sed 's/^[ \t]*//')
      
      # Determine segment
      seg="Internal / Other"
      case "$ips" in
        *172.28.*) seg="provider-b (Transit)" ;;
        *172.29.*) seg="provider-a (VPC)" ;;
        *10.100.*) seg="WireGuard Overlay" ;;
        *127.0.0.1*) seg="Loopback" ;;
      esac
      
      printf "  %-30s %-12s %-18s %-20s\n" "$c" "$dev" "$ips" "$seg"
    done < <(sudo podman exec "$c" ip -br addr show 2>/dev/null | grep -v "^lo ")
  else
    printf "  %-30s %-12s %-18s %-20s\n" "$c" "[OFFLINE]" "--" "--"
  fi
done
echo "${SEPARATOR}"
