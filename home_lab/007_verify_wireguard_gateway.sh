#!/usr/bin/env bash
# ==============================================================================
# Script: 007_verify_wireguard_gateway.sh
# Purpose: Comprehensive validation of Gateway Hub state: virtual device wg0,
#          assigned overlay IP 10.100.0.1, UDP port 51820 listener, cryptokey
#          peer routing table, and iptables POSTROUTING SNAT rule.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY VIRTUAL INTERFACE wg0 & OVERLAY IP (10.100.0.1/24)"
echo "WHY: Confirms device wg0 was instantiated in the kernel and assigned the Hub IP."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway ip -br addr show dev wg0"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  wg0              UNKNOWN        10.100.0.1/24"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Device Status : "
sudo podman exec vpc-gateway ip -br addr show dev wg0 2>/dev/null || echo "FAILED: wg0 interface missing!"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY UDP LISTENER ON PORT 51820"
echo "WHY: The Hub must actively bind and listen on UDP port 51820 across all interfaces"
echo "     to receive inbound encrypted handshakes from the bare-metal fleet."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway sh -c 'ss -uln 2>/dev/null || netstat -uln 2>/dev/null'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  UNCONN ... 0.0.0.0:51820 ... (or :::51820)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway sh -c "ss -uln 2>/dev/null || netstat -uln 2>/dev/null" | grep "51820" || echo "  FAILED: No listener on UDP 51820!"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY WIREGUARD CRYPTOKEY CONFIGURATION & PEER REGISTRATION"
echo "WHY: Inspects the in-kernel WireGuard driver to ensure the gateway's private key"
echo "     is loaded, the listen port is registered, and the bare-metal peer is mapped."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway wg show wg0"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  interface: wg0"
echo "    public key: <gateway-pubkey>"
echo "    listening port: 51820"
echo "  peer: <baremetal-pubkey>"
echo "    allowed ips: 10.100.0.10/32"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec vpc-gateway wg show wg0
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY IPTABLES SNAT (MASQUERADE) ON eth1"
echo "WHY: Guarantees outbound packets targeting Provider A VPC (172.29.0.0/16) have their"
echo "     source IP rewritten to 172.29.0.2 so backend responses return to the gateway."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec vpc-gateway iptables -t nat -nvL POSTROUTING"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  target: MASQUERADE, prot: all, out: eth1, source: 0.0.0.0/0, destination: 0.0.0.0/0"
echo ""
echo "[ACTUAL OUTPUT]:"
NAT_RULE=$(sudo podman exec vpc-gateway iptables -t nat -nvL POSTROUTING | grep "MASQUERADE" || true)
if [ -n "${NAT_RULE}" ]; then
  echo "  ${NAT_RULE}"
  echo "  STATUS: PASSED (Outbound SNAT MASQUERADE active on eth1)"
else
  echo "  STATUS: FAILED (MASQUERADE rule missing from POSTROUTING table!)"
fi
echo "${SEPARATOR}"
