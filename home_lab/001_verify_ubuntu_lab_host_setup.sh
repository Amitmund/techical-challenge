#!/usr/bin/env bash
# ==============================================================================
# Script: 001_verify_ubuntu_lab_host_setup.sh
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
echo "  command -v podman wg iptables curl ip jq"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  podman     : /usr/bin/podman (or /bin/podman)"
echo "  wg         : /usr/bin/wg"
echo "  iptables   : /usr/sbin/iptables"
echo "  curl       : /usr/bin/curl"
echo "  ip         : /usr/sbin/ip (or /bin/ip)"
echo "  jq         : /usr/bin/jq"
echo ""
echo "[ACTUAL OUTPUT]:"
ALL_PKGS_OK=true
for bin in podman wg iptables curl ip jq; do
  BIN_PATH=$(command -v "$bin" 2>/dev/null || echo "NOT FOUND")
  printf "  %-10s : %s\n" "$bin" "$BIN_PATH"
  if [ "$BIN_PATH" = "NOT FOUND" ]; then
    ALL_PKGS_OK=false
  fi
done
if [ "$ALL_PKGS_OK" = true ]; then
  echo "  STATUS: ALL REQUIRED BINARIES PRESENT"
else
  echo "  STATUS: ERROR - MISSING ONE OR MORE BINARIES"
fi
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
echo "  wireguard        : [LOADED]"
echo "  iptable_nat      : [LOADED]"
echo "  iptable_filter   : [LOADED]"
echo ""
echo "[ACTUAL OUTPUT]:"
ALL_MODS_OK=true
for mod in wireguard iptable_nat iptable_filter; do
  if lsmod | grep -q "^${mod}"; then
    printf "  %-16s : [LOADED]\n" "$mod"
  else
    printf "  %-16s : [MISSING / NOT LOADED]\n" "$mod"
    ALL_MODS_OK=false
  fi
done
if [ "$ALL_MODS_OK" = true ]; then
  echo "  STATUS: ALL KERNEL MODULES LOADED"
else
  echo "  STATUS: ERROR - ONE OR MORE KERNEL MODULES MISSING"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY PODMAN SYSTEM SOCKET SERVICE"
echo "WHY: Kind interacts with Podman via Docker-compatible socket emulation."
echo "     The podman.socket unit must be active and listening on the host filesystem."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo systemctl is-active podman.socket"
echo "  test -S /run/podman/podman.sock"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Unit State   : active"
echo "  Socket Path  : /run/podman/podman.sock (EXISTS)"
echo ""
echo "[ACTUAL OUTPUT]:"
SOCKET_STATE=$(sudo systemctl is-active podman.socket 2>/dev/null || echo "inactive")
printf "  %-14s : %s\n" "Unit State" "$SOCKET_STATE"

if [ -S /run/podman/podman.sock ]; then
  printf "  %-14s : /run/podman/podman.sock [EXISTS]\n" "Socket File"
else
  printf "  %-14s : /run/podman/podman.sock [NOT FOUND]\n" "Socket File"
fi
sudo systemctl status podman.socket --no-pager 2>/dev/null | grep -E "(Active:|Listen:)" || true
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY KIND (KUBERNETES IN DOCKER/PODMAN) INSTALLATION"
echo "WHY: Provisions the local single-zone Kubernetes cluster node to host"
echo "     the simulated core VPC workloads."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  command -v kind"
echo "  kind version"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Binary  : /usr/local/bin/kind (or /usr/bin/kind)"
echo "  Version : kind v0.24.0 (or higher) go1.x.x linux/amd64"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Binary  : "
command -v kind || echo "NOT FOUND"
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
echo "  command -v kubectl"
echo "  kubectl version --client --output=yaml | grep -E '(gitVersion|platform)'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Binary         : /usr/local/bin/kubectl (or /usr/bin/kubectl)"
echo "  Client Version : gitVersion: v1.x.x / platform: linux/amd64"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Binary  : "
command -v kubectl || echo "NOT FOUND"
echo "  Client Version :"
if command -v kubectl &>/dev/null; then
  kubectl version --client --output=yaml 2>/dev/null | grep -E "(gitVersion|platform)" || kubectl version --client
else
  echo "  kubectl binary missing"
fi
echo "${SEPARATOR}"
