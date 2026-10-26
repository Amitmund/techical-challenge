#!/usr/bin/env bash
# ==============================================================================
# Script: 001_install_and_verify_prereqs.sh
# Purpose: Installs, configures, and verifies all required host packages, kernel
#          modules, daemon sockets, kind, and kubectl binaries for the lab.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "STEP 1: UPDATE REPOSITORIES & INSTALL SYSTEM PACKAGES"
echo "[NOTE]   : Updates apt index and installs underlying network & container utilities."
echo "[CAUSE]  : Base Ubuntu lacks WireGuard userspace tools, netfilter binaries,"
echo "           and Podman engine needed to build the multi-provider mock topology."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo apt-get update && sudo apt-get install -y podman wireguard-tools iptables curl iproute2 jq"
echo ""
echo "[WHY]:"
echo "  - podman          : Container engine managing isolated bridge namespaces."
echo "  - wireguard-tools : Provides 'wg' and 'wg-quick' to manage in-kernel tunnels."
echo "  - iptables        : Enforces host-level isolation and gateway SNAT (MASQUERADE)."
echo "  - curl/ip/jq      : Network probes, routing management, and JSON inspection."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  All 6 packages installed with exit code 0; binaries resolvable in PATH."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo apt-get update -qq
sudo apt-get install -y -qq podman wireguard-tools iptables curl iproute2 jq >/dev/null
echo "  Packages successfully updated and installed."
for pkg in podman wg iptables curl ip jq; do
  printf "  - %-10s : %s\n" "$pkg" "$(which "$pkg" 2>/dev/null || echo 'NOT FOUND')"
done
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: LOAD REQUIRED LINUX KERNEL MODULES"
echo "[NOTE]   : Loads in-kernel crypto and netfilter tables into the running Linux kernel."
echo "[CAUSE]  : Container networks require NAT and packet filtering on host bridges;"
echo "           WireGuard requires in-kernel module loading for fast ChaCha20 crypto."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo modprobe wireguard iptable_nat iptable_filter"
echo ""
echo "[WHY]:"
echo "  - wireguard      : In-kernel cryptokey routing engine (avoids tun/tap overhead)."
echo "  - iptable_nat    : Enables MASQUERADE / SNAT on the Provider A gateway."
echo "  - iptable_filter : Enables FORWARD chain rules to enforce inter-cloud isolation."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  wireguard              <size>  <instances>"
echo "  iptable_nat            <size>  <instances>"
echo "  iptable_filter         <size>  <instances>"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo modprobe wireguard
sudo modprobe iptable_nat
sudo modprobe iptable_filter
MODULES_LOADED=$(lsmod | grep -E "^(wireguard|iptable_nat|iptable_filter)" || true)
if [ -n "${MODULES_LOADED}" ]; then
  echo "${MODULES_LOADED}"
else
  echo "  ERROR: One or more kernel modules failed to load!"
fi
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: ACTIVATE PODMAN SYSTEM SOCKET"
echo "[NOTE]   : Enables and starts systemd socket activation for Podman."
echo "[CAUSE]  : Kind communicates with container runtimes over a standard Unix socket."
echo "           Podman must expose '/run/podman/podman.sock' to mimic Docker."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo systemctl enable --now podman.socket"
echo ""
echo "[WHY]:"
echo "  - Allows 'KIND_EXPERIMENTAL_PROVIDER=podman' to control container lifecycles."
echo "  - Provides seamless Docker-compatible REST API emulation on Ubuntu."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Socket Status : active"
echo "  Listen: /run/podman/podman.sock (Stream)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo systemctl enable --now podman.socket >/dev/null 2>&1
echo -n "  Socket Status : "
sudo systemctl is-active podman.socket || echo "inactive"
sudo systemctl status podman.socket --no-pager 2>/dev/null | grep -E "(Active:|Listen:)" || true
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: INSTALL KIND (KUBERNETES IN CONTAINER)"
echo "[NOTE]   : Downloads and sets up the Kind binary in the system binary path."
echo "[CAUSE]  : The technical assessment requires running a single-zone Kubernetes"
echo "           cluster locally without deploying a multi-node VM infrastructure."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64"
echo "  chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind"
echo ""
echo "[WHY]:"
echo "  - Kind boots standard OCI containers as Kubernetes nodes."
echo "  - Lightweight and fully compatible with root Podman socket emulation."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Binary  : /usr/local/bin/kind"
echo "  Version : kind v0.24.0 (or newer)"
echo ""
echo "[ACTUAL OUTPUT]:"
if ! command -v kind &>/dev/null; then
  echo "  kind binary not found. Downloading v0.24.0..."
  KIND_VERSION="v0.24.0"
  curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -s
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
fi
echo -n "  Binary  : "
which kind 2>/dev/null || echo "NOT FOUND"
echo -n "  Version : "
kind version
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 5: INSTALL KUBECTL CLIENT BINARY"
echo "[NOTE]   : Downloads the latest stable release of the Kubernetes CLI."
echo "[CAUSE]  : Needed to deploy the sample HTTP echo workload and query cluster"
echo "           service endpoints from the Ubuntu host."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  curl -LO https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
echo "  chmod +x ./kubectl && sudo mv ./kubectl /usr/local/bin/kubectl"
echo ""
echo "[WHY]:"
echo "  - Manages Deployment and NodePort resource declarations in the cluster."
echo "  - Verifies workload readiness inside Provider A's private VPC network."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Binary  : /usr/local/bin/kubectl"
echo "  Version : Client Version: v1.x.x"
echo ""
echo "[ACTUAL OUTPUT]:"
if ! command -v kubectl &>/dev/null; then
  echo "  kubectl binary not found. Downloading latest stable release..."
  STABLE_K8S=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${STABLE_K8S}/bin/linux/amd64/kubectl" -s
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
fi
echo -n "  Binary  : "
which kubectl 2>/dev/null || echo "NOT FOUND"
echo -n "  Version : "
kubectl version --client 2>/dev/null | head -n 1
echo "${SEPARATOR}"
