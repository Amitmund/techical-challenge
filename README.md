# techical-challenge
Technical challenges, that from provider B, with only the public network, should be able to connect to radis cluster on provider A, and hit miss should be able to reach a simple app on the kind k8s cluster.

# setting up this one at my ubuntu system

This step-by-step guide builds and verifies the exact dual-network topology on an Ubuntu host using Docker, `kind`, and in-kernel WireGuard.

---

### Architecture & Network Map

```
                     [ Ubuntu Host ]
                            │
       ┌────────────────────┴────────────────────┐
       ▼                                         ▼
[ podman Network: provider-b ]        [ podman Network: provider-a ]
  Subnet: 172.28.0.0/16 (Public)        Subnet: 172.29.0.0/16 (Private VPC)
       │                                         │
       ├─ [ baremetal-node ]                     ├─ [ saas-redis ]
       │    eth0: 172.28.0.100                   │    eth0: 172.29.0.20 (No host ports)
       │    wg0:  10.100.0.10                    │
       │                                         ├─ [ provider-a-k8s-control-plane ]
       │                                         │    eth1: 172.29.0.30
       │                                         │    Service: NodePort 30080
       │                                         │
       │ (WireGuard UDP 51820 Handshake)         │
       └────────────────────────────────────────►├─ [ vpc-gateway ]
                                                      eth0: 172.28.0.2 (provider-b)
                                                      eth1: 172.29.0.2 (provider-a)
                                                      wg0:  10.100.0.1
                                                      SNAT / MASQUERADE -> eth1

```

---
Running this topology with **Podman** requires root privileges (`sudo`) to manage network namespaces, load kernel modules, manipulate `iptables`, and attach multiple virtual interfaces directly to containers without rootless user-namespace ID mapping conflicts.

---

### Step 1: Host Prerequisites & Workspace Setup

Install Podman, `kind`, `kubectl`, and the required host kernel modules.

```bash
# 1. Update apt and install required tools
sudo apt-get update
sudo apt-get install -y podman wireguard-tools iptables curl iproute2 jq

# 2. Ensure host kernel modules are loaded
sudo modprobe wireguard
sudo modprobe iptable_nat
sudo modprobe iptable_filter

# 3. Enable Podman system service
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

# 6. Create working directory
mkdir -p ~/wireguard-mock && cd ~/wireguard-mock

```

---

### Step 2: Create Isolated Podman Networks

Create two bridge networks to isolate the simulated public internet from the private VPC.

```bash
# Clean up prior test runs
sudo podman rm -f baremetal-node vpc-gateway saas-redis provider-a-k8s-control-plane 2>/dev/null || true
sudo podman network rm provider-a provider-b 2>/dev/null || true

# Create Provider B network (simulated public internet / bare-metal network)
sudo podman network create \
  --subnet 172.28.0.0/16 \
  provider-b

# Create Provider A network (private isolated VPC)
sudo podman network create \
  --subnet 172.29.0.0/16 \
  provider-a

```

---

### Step 3: Deploy the Managed SaaS Service (Redis)

Launch Redis on `provider-a` at static IP `172.29.0.20` with no published host ports.

```bash
sudo podman run -d \
  --name saas-redis \
  --network provider-a \
  --ip 172.29.0.20 \
  --restart unless-stopped \
  docker.io/library/redis:7-alpine redis-server --protected-mode no

```

---

### Step 4: Deploy the Kubernetes Cluster with Podman

Use `KIND_EXPERIMENTAL_PROVIDER=podman` to initialize the cluster and connect it to `provider-a` at IP `172.29.0.30`.

```bash
# 1. Create Kind cluster using Podman engine
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s 2>/dev/null || true
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name provider-a-k8s

# Export kubeconfig so kubectl works seamlessly under sudo
export KUBECONFIG="$(sudo kind get kubeconfig-path --name=provider-a-k8s 2>/dev/null || sudo podman exec provider-a-k8s-control-plane cat /etc/kubernetes/admin.conf > /tmp/admin.conf && echo /tmp/admin.conf)"

# 2. Attach Kind control-plane container to the Provider A VPC network
sudo podman network connect --ip 172.29.0.30 provider-a provider-a-k8s-control-plane

# 3. Deploy the sample HTTP service exposed on NodePort 30080
cat <<EOF | sudo kubectl --kubeconfig=${KUBECONFIG} apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-workload
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-workload
  template:
    metadata:
      labels:
        app: sample-workload
    spec:
      containers:
      - name: web
        image: docker.io/hashicorp/http-echo:0.2.3
        args: ["-text=HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: sample-service
  namespace: default
spec:
  type: NodePort
  selector:
    app: sample-workload
  ports:
  - port: 80
    targetPort: 5678
    nodePort: 30080
EOF

# 4. Wait for deployment readiness
sudo kubectl --kubeconfig=${KUBECONFIG} rollout status deployment/sample-workload --timeout=60s

```

---

### Step 5: Deploy the Dual-Homed VPC Gateway

Connect the gateway to both `provider-b` (`172.28.0.2`) and `provider-a` (`172.29.0.2`).

```bash
# 1. Start gateway container on provider-b
sudo podman run -d \
  --name vpc-gateway \
  --network provider-b \
  --ip 172.28.0.2 \
  --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  docker.io/library/alpine:3.20 sleep infinity

# 2. Attach second interface (eth1) to provider-a
sudo podman network connect --ip 172.29.0.2 provider-a vpc-gateway

# 3. Install networking utilities inside the gateway
sudo podman exec vpc-gateway apk add --no-cache wireguard-tools iptables iproute2

# 4. Generate Gateway WireGuard keypair
sudo podman exec vpc-gateway sh -c "
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/gw_private.key | wg pubkey > /etc/wireguard/gw_public.key
"

```

---

### Step 6: Deploy the Bare-Metal Node

Launch the isolated client container on `provider-b` at static IP `172.28.0.100`.

```bash
# 1. Start baremetal container on provider-b
sudo podman run -d \
  --name baremetal-node \
  --network provider-b \
  --ip 172.28.0.100 \
  --privileged \
  docker.io/library/alpine:3.20 sleep infinity

# 2. Install testing tools and WireGuard on the bare-metal node
sudo podman exec baremetal-node apk add --no-cache wireguard-tools iptables iproute2 curl redis

# 3. Generate Bare-Metal WireGuard keypair
sudo podman exec baremetal-node sh -c "
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/bm_private.key | wg pubkey > /etc/wireguard/bm_public.key
"

```

---

### Step 7: Negative Test (Prove Baseline Isolation)

Verify that `baremetal-node` **cannot** route to Provider A's private VPC before the tunnel is configured.

```bash
echo -n "Testing Redis reachability (should FAIL): "
if sudo podman exec baremetal-node nc -z -w 2 172.29.0.20 6379; then
  echo "ERROR: Redis is reachable! Networks are not isolated."
else
  echo "PASSED: Redis is unreachable (VPC is strictly isolated)."
fi

echo -n "Testing K8s Service reachability (should FAIL): "
if sudo podman exec baremetal-node nc -z -w 2 172.29.0.30 30080; then
  echo "ERROR: K8s is reachable! Networks are not isolated."
else
  echo "PASSED: K8s NodePort is unreachable."
fi

```

---

### Step 8: Configure and Activate the WireGuard Tunnel

Exchange keys, assign overlay IPs (`10.100.0.1` and `10.100.0.10`), and enable SNAT on the gateway interface facing Provider A.

```bash
# 1. Read public keys
GW_PUB=$(sudo podman exec vpc-gateway cat /etc/wireguard/gw_public.key)
BM_PUB=$(sudo podman exec baremetal-node cat /etc/wireguard/bm_public.key)

# 2. Configure Gateway (Hub)
sudo podman exec vpc-gateway sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/gw_private.key)

# SNAT outbound packets passing through eth1 into Provider A VPC
PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE

[Peer]
# Bare-Metal Node
PublicKey = ${BM_PUB}
AllowedIPs = 10.100.0.10/32
EOF

wg-quick up wg0
"

# 3. Configure Bare-Metal (Spoke)
sudo podman exec baremetal-node sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.10/24
PrivateKey = \$(cat /etc/wireguard/bm_private.key)

[Peer]
PublicKey = ${GW_PUB}
Endpoint = 172.28.0.2:51820
# Route the entire VPC CIDR through wg0
AllowedIPs = 172.29.0.0/16
PersistentKeepalive = 25
EOF

wg-quick up wg0
"

```

---

### Step 9: Positive Verification (End-to-End Validation)

Execute the verification commands from `baremetal-node` to confirm connectivity across the tunnel.

#### 1. Check WireGuard Link & Handshake

```bash
sudo podman exec baremetal-node wg show

```

*(Look for `latest handshake: ... seconds ago` and active data transfer counts)*

#### 2. Query Managed SaaS (Redis)

```bash
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 ping

```

*Expected output:*

```text
PONG

```

#### 3. Query Kubernetes Sample Service

```bash
sudo podman exec baremetal-node curl -s http://172.29.0.30:30080

```

*Expected output:*

```text
HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard

```

---

### Step 10: Teardown & Clean Up

To delete all containers, networks, and the Kind cluster:

```bash
sudo podman rm -f baremetal-node vpc-gateway saas-redis 2>/dev/null || true
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s 2>/dev/null || true
sudo podman network rm provider-a provider-b 2>/dev/null || true
rm -rf ~/wireguard-mock /tmp/admin.conf

```
