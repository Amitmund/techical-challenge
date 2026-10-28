#!/usr/bin/env bash
# ==============================================================================
# Script: 005_verify_gateway_and_baremetal.sh
# Purpose: Validates container lifecycles, dual-homed gateway interfaces,
#          bare-metal single-homed interface, IP forwarding, tool availability,
#          and underlay L3 transit reachability prior to WireGuard tunnel setup.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY CONTAINER RUNTIME STATUS"
echo "WHY: Confirms both nodes are running without unexpected restarts or errors."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman ps --filter 'name=vpc-gateway|baremetal-node' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  NAMES             STATUS       IMAGE"
echo "  baremetal-node    Up ...       docker.io/library/alpine:3.20"
echo "  vpc-gateway       Up ...       docker.io/library/alpine:3.20"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman ps --filter "name=vpc-gateway|baremetal-node" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY GATEWAY DUAL-HOMED NETWORK INTERFACES"
echo "WHY: Confirms vpc-gateway has two virtual NICs: eth0 on provider-b (172.28.0.2)"
echo "     and eth1 on provider-a (172.29.0.2)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman inspect vpc-gateway \\"
echo "    --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}: IP={{\$v.IPAddress}} (Gateway={{\$v.Gateway}}){{\"\n\"}}{{end}}'"
echo "  sudo podman exec vpc-gateway ip -br addr show"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  provider-b: IP=172.28.0.2"
echo "  provider-a: IP=172.29.0.2"
echo "  eth0 ... 172.28.0.2/16"
echo "  eth1 ... 172.29.0.2/16"
echo ""
echo "[ACTUAL OUTPUT]:"
echo "  Podman IPAM network mappings:"
sudo podman inspect vpc-gateway \
  --format '{{range $k, $v := .NetworkSettings.Networks}}  - {{$k}}: IP={{$v.IPAddress}} (Gateway={{$v.Gateway}}){{"\n"}}{{end}}'
echo "  In-kernel network interfaces:"
sudo podman exec vpc-gateway ip -br addr show
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY BARE-METAL SINGLE-HOMED INTERFACE"
echo "WHY: Confirms baremetal-node is connected only to provider-b (172.28.0.100)"
echo "     and has no direct connection to the private VPC (provider-a)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman inspect baremetal-node \\"
echo "    --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}: IP={{\$v.IPAddress}}{{\"\n\"}}{{end}}'"
echo "  sudo podman exec baremetal-node ip -br addr show"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  provider-b: IP=172.28.0.100"
echo "  eth0 ... 172.28.0.100/16 (no eth1 present)"
echo ""
echo "[ACTUAL OUTPUT]:"
echo "  Podman IPAM network mappings:"
sudo podman inspect baremetal-node \
  --format '{{range $k, $v := .NetworkSettings.Networks}}  - {{$k}}: IP={{$v.IPAddress}}{{"\n"}}{{end}}'
echo "  In-kernel network interfaces:"
sudo podman exec baremetal-node ip -br addr show
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY KERNEL IP FORWARDING ON GATEWAY"
echo "WHY: Packet routing between wg0 and eth1 requires the kernel forwarder"
echo "     to be active (net.ipv4.ip_forward = 1)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway sysctl net.ipv4.ip_forward"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  net.ipv4.ip_forward = 1"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway sysctl net.ipv4.ip_forward
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY INSTALLED UTILITIES IN BOTH CONTAINERS"
echo "WHY: Confirms wg, iptables, ip, curl, and redis-cli binaries are resolvable."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway which wg iptables ip"
echo "  sudo podman exec baremetal-node which wg iptables ip curl redis-cli"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  vpc-gateway    : wg, iptables, ip present"
echo "  baremetal-node : wg, iptables, ip, curl, redis-cli present"
echo ""
echo "[ACTUAL OUTPUT]:"
echo "  vpc-gateway:"
for bin in wg iptables ip; do
  RES=$(sudo podman exec vpc-gateway which "$bin" 2>/dev/null || echo "NOT FOUND")
  printf "    - %-10s : %s\n" "$bin" "$RES"
done

echo "  baremetal-node:"
for bin in wg iptables ip curl redis-cli; do
  RES=$(sudo podman exec baremetal-node which "$bin" 2>/dev/null || echo "NOT FOUND")
  printf "    - %-10s : %s\n" "$bin" "$RES"
done
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "6. VERIFY UNDERLAY TRANSIT REACHABILITY (BARE-METAL -> GATEWAY WAN)"
echo "WHY: The bare-metal node must be able to reach the gateway's public transit"
echo "     IP (172.28.0.2) over provider-b to negotiate the WireGuard handshake."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec baremetal-node ping -c 2 -W 1 172.28.0.2"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  2 packets transmitted, 2 received, 0% packet loss."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Underlay Ping Probe: "
if sudo podman exec baremetal-node ping -c 2 -W 1 172.28.0.2 >/dev/null 2>&1; then
  echo "PASSED (Underlay transit WAN is reachable for WireGuard handshakes)"
else
  echo "FAILED (Cannot reach 172.28.0.2 over provider-b)"
fi
echo "${SEPARATOR}"
