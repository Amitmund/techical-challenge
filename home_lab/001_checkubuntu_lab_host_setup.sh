#!/usr/bin/env bash
# ==============================================================================
# Script: 001_checkubuntu_lab_host_setup.sh
# Purpose: Step-by-step verification of host packages, kernel modules,
#          Podman socket, kind, and kubectl binaries with command audit visibility.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "1. VERIFY CORE CLI PACKAGES INSTALLED"
echo "WHY: Fundamental tools required for container lifecycles (podman), WireGuard"
echo "     cryptokey operations (wg), netfilter rules (iptables), L3 routing (ip),"
echo "     JSON parsing (jq), and network probing (curl)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  which podman wg iptables curl ip jq"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  /usr/bin/podman (or /bin/podman)"
echo "  /usr/bin/wg"
echo "  /usr/sbin/iptables"
echo "  /usr/bin/curl"
echo "  /usr/sbin/ip (or /bin/ip)"
echo "  /usr/bin/jq"
echo ""
echo "[ACTUAL OUTPUT]:"
for bin in podman wg iptables curl ip jq; do
  BIN_PATH=$(which "$bin" 2>/dev/null || echo "NOT FOUND")
  printf "  %-10s : %s\n" "$bin" "$BIN_PATH"
done
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY LINUX KERNEL MODULES LOADED"
echo "WHY: WireGuard must run in-kernel for line-rate ChaCha20-Poly1305 cryptokey"
echo "     routing. iptable_nat and iptable_filter are required by the host and"
echo "     gateway to enforce cross-bridge drops and outbound SNAT (MASQUERADE)."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  lsmod | grep -E '^(wireguard|iptable_nat|iptable_filter)'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  wireguard              <size>  <instances>"
echo "  iptable_nat            <size>  <instances>"
echo "  iptable_filter         <size>  <instances>"
echo ""
echo "[ACTUAL OUTPUT]:"
MODULES=$(lsmod | grep -E "^(wireguard|iptable_nat|iptable_filter)" || true)
if [ -n "${MODULES}" ]; then
  echo "${MODULES}"
else
  echo "  ERROR: One or more required kernel modules are NOT loaded."
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY PODMAN SYSTEM SOCKET SERVICE"
echo "WHY: Kind interacts with Podman via Docker-compatible socket emulation."
echo "     The podman.socket unit must be active and listening on the host."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo systemctl is-active podman.socket"
echo "  sudo systemctl status podman.socket --no-pager | grep -E '(Active:|Listen:)'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  active"
echo "  Active: active (listening) ..."
echo "  Listen: /run/podman/podman.sock ..."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Socket Status : "
sudo systemctl is-active podman.socket || echo "inactive"
sudo systemctl status podman.socket --no-pager 2>/dev/null | grep -E "(Active:|Listen:)" || true
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY KIND (KUBERNETES IN DOCKER/PODMAN) INSTALLATION"
echo "WHY: Provisions the local single-zone Kubernetes cluster node to host"
echo "     the simulated core VPC workloads."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  which kind"
echo "  kind version"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  /usr/local/bin/kind (or /usr/bin/kind)"
echo "  kind v0.24.0 (or higher) go1.x.x linux/amd64"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Binary  : "
which kind 2>/dev/null || echo "NOT FOUND"
echo -n "  Version : "
if command -v kind &>/dev/null; then
  kind version
else
  echo "kind binary missing"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. VERIFY KUBECTL CLIENT BINARY INSTALLATION"
echo "WHY: Interacts with the Kind Kubernetes control plane to deploy the sample"
echo "     HTTP workload and inspect NodePort service endpoints inside Provider A."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  which kubectl"
echo "  kubectl version --client --output=yaml | grep -E '(gitVersion|platform)'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  /usr/local/bin/kubectl (or /usr/bin/kubectl)"
echo "  gitVersion: v1.x.x"
echo "  platform: linux/amd64"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Binary  : "
which kubectl 2>/dev/null || echo "NOT FOUND"
echo "  Client Version :"
if command -v kubectl &>/dev/null; then
  kubectl version --client --output=yaml 2>/dev/null | grep -E "(gitVersion|platform)" || kubectl version --client
else
  echo "  kubectl binary missing"
fi
echo "${SEPARATOR}"
