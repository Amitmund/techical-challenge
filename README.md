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
[ Docker Network: provider-b ]        [ Docker Network: provider-a ]
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

### Step 1: Host Prerequisites & Workspace Setup

Ensure the host has the kernel WireGuard module loaded, along with `docker`, `kind`, and `kubectl`.

```bash
# 1. Update apt and install required tools
sudo apt-get update
sudo apt-get install -y docker.io wireguard-tools iptables curl iproute2 jq

# 2. Enable Docker and load host kernel modules
sudo systemctl enable --now docker
sudo modprobe wireguard
sudo modprobe iptable_nat
sudo modprobe iptable_filter

# 3. Install kind (if not already installed)
if ! command -v kind &>/dev/null; then
  KIND_VERSION="v0.24.0"
  curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
fi

# 4. Install kubectl (if not already installed)
if ! command -v kubectl &>/dev/null; then
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x ./kubectl
  sudo mv ./kubectl /usr/local/bin/kubectl
fi

# 5. Create working directory
mkdir -p ~/wireguard-mock && cd ~/wireguard-mock

```

---

### Step 2: Create Isolated Docker Networks

Create two isolated bridge networks. By default, Docker isolates traffic between user-defined bridge networks via internal `DOCKER-ISOLATION` iptables chains.

```bash
# Clean up prior test runs
docker rm -f baremetal-node vpc-gateway saas-redis provider-a-k8s-control-plane 2>/dev/null || true
docker network rm provider-a provider-b 2>/dev/null || true

# Create Provider B (simulated public internet / bare-metal network)
docker network create \
  --subnet 172.28.0.0/16 \
  --opt com.docker.network.bridge.name=br-provider-b \
  provider-b

# Create Provider A (private isolated VPC)
docker network create \
  --subnet 172.29.0.0/16 \
  --opt com.docker.network.bridge.name=br-provider-a \
  provider-a

```

---

### Step 3: Deploy the Managed SaaS Service (Redis)

Launch Redis directly inside `provider-a` at static IP `172.29.0.20`. It publishes **no ports** to the host.

```bash
docker run -d \
  --name saas-redis \
  --network provider-a \
  --ip 172.29.0.20 \
  --restart unless-stopped \
  redis:7-alpine redis-server --protected-mode no

```

---

### Step 4: Deploy the Kubernetes Cluster & Sample Workload

Spin up a lightweight `kind` cluster and attach its control-plane node directly to `provider-a` at IP `172.29.0.30`.

```bash
# 1. Create Kind cluster
kind delete cluster --name provider-a-k8s 2>/dev/null || true
kind create cluster --name provider-a-k8s

# 2. Attach Kind control-plane container to the Provider A VPC network
docker network connect --ip 172.29.0.30 provider-a provider-a-k8s-control-plane

# 3. Deploy a sample HTTP service exposed on NodePort 30080
cat <<EOF | kubectl apply -f -
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
        image: hashicorp/http-echo:0.2.3
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
kubectl rollout status deployment/sample-workload --timeout=60s

```

---

### Step 5: Deploy the Dual-Homed VPC Gateway

The gateway connects to both `provider-b` (`172.28.0.2`, simulated public internet) and `provider-a` (`172.29.0.2`, internal VPC).

```bash
# 1. Start gateway container on provider-b
docker run -d \
  --name vpc-gateway \
  --network provider-b \
  --ip 172.28.0.2 \
  --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  alpine:3.20 sleep infinity

# 2. Attach second interface (eth1) to provider-a
docker network connect --ip 172.29.0.2 provider-a vpc-gateway

# 3. Install networking utilities inside the gateway
docker exec vpc-gateway apk add --no-cache wireguard-tools iptables iproute2

# 4. Generate Gateway WireGuard keypair
docker exec vpc-gateway sh -c "
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/gw_private.key | wg pubkey > /etc/wireguard/gw_public.key
"

```

---

### Step 6: Deploy the Bare-Metal Node

Launch the isolated client container on `provider-b` at static IP `172.28.0.100`.

```bash
# 1. Start baremetal container on provider-b
docker run -d \
  --name baremetal-node \
  --network provider-b \
  --ip 172.28.0.100 \
  --privileged \
  alpine:3.20 sleep infinity

# 2. Install testing tools and WireGuard on bare-metal node
docker exec baremetal-node apk add --no-cache wireguard-tools iptables iproute2 curl redis

# 3. Generate Bare-Metal WireGuard keypair
docker exec baremetal-node sh -c "
  mkdir -p /etc/wireguard
  wg genkey | tee /etc/wireguard/bm_private.key | wg pubkey > /etc/wireguard/bm_public.key
"

```

---

### Step 7: Negative Test (Prove Baseline Isolation)

Confirm that `baremetal-node` **cannot** route to Provider A's private VPC before the tunnel is configured.

```bash
echo -n "Testing Redis reachability (should FAIL): "
if docker exec baremetal-node nc -z -w 2 172.29.0.20 6379; then
  echo "ERROR: Redis is reachable! Networks are not isolated."
else
  echo "PASSED: Redis is unreachable (VPC is strictly isolated)."
fi

echo -n "Testing K8s Service reachability (should FAIL): "
if docker exec baremetal-node nc -z -w 2 172.29.0.30 30080; then
  echo "ERROR: K8s is reachable! Networks are not isolated."
else
  echo "PASSED: K8s NodePort is unreachable."
fi

```

---

### Step 8: Configure and Bring Up WireGuard Tunnel

Exchange keys, assign overlay IPs (`10.100.0.1` and `10.100.0.10`), and configure kernel SNAT on the gateway.

```bash
# 1. Read public keys
GW_PUB=$(docker exec vpc-gateway cat /etc/wireguard/gw_public.key)
BM_PUB=$(docker exec baremetal-node cat /etc/wireguard/bm_public.key)

# 2. Configure Gateway (Hub)
docker exec vpc-gateway sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/gw_private.key)

# SNAT outbound traffic traversing eth1 into Provider A VPC
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
docker exec baremetal-node sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.10/24
PrivateKey = \$(cat /etc/wireguard/bm_private.key)

[Peer]
PublicKey = ${GW_PUB}
Endpoint = 172.28.0.2:51820
# Route the VPC CIDR through the WireGuard interface
AllowedIPs = 172.29.0.0/16
PersistentKeepalive = 25
EOF

wg-quick up wg0
"

```

---

### Step 9: Positive Verification (End-to-End Validation)

Execute the verification tests from `baremetal-node` through the tunnel into Provider A.

#### 1. Verify WireGuard Link & Handshake

```bash
docker exec baremetal-node wg show

```

*(Look for `latest handshake: ... seconds ago` and `transfer: ... KiB received, ... KiB sent`)*

#### 2. Verify Managed SaaS (Redis) Access

```bash
docker exec baremetal-node redis-cli -h 172.29.0.20 ping

```

*Expected output:*

```text
PONG

```

#### 3. Verify Kubernetes Sample Service Access

```bash
docker exec baremetal-node curl -s http://172.29.0.30:30080

```

*Expected output:*

```text
HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard

```

---

### Step 10: Teardown & Clean Up

To destroy the local mock environment completely:

```bash
docker rm -f baremetal-node vpc-gateway saas-redis 2>/dev/null || true
kind delete cluster --name provider-a-k8s 2>/dev/null || true
docker network rm provider-a provider-b 2>/dev/null || true
rm -rf ~/wireguard-mock

```
