# 1. Update and install packages
sudo apt-get update
sudo apt-get install -y podman wireguard-tools iptables curl iproute2 jq

# 2. Load kernel modules on Ubuntu host
sudo modprobe wireguard
sudo modprobe iptable_nat
sudo modprobe iptable_filter

# 3. Enable Podman system socket
sudo systemctl enable --now podman.socket

# 4. Install kind (if not already installed)
if ! command -v kind &>/dev/null; then
  KIND_VERSION="v0.24.0"
  curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
fi

# 5. Install kubectl (if not already installed)
if ! command -v kubectl &>/dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
fi
