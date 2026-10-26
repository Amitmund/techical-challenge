# SRE Technical Challenge: Engineering Notes & Lab Runbook

This document contains the complete **Design Notes (Deliverable 1)**, the **Ubuntu + Podman + Kind + WireGuard Simulation Runbook (Deliverable 2)**, and the **Production Plan (Deliverable 3)**.

---

## Part 1: Design Notes (Deliverable 1)

### 1.1 Architecture & Topology

```
┌───────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Provider A (Private VPC: Production 10.0.0.0/16 | Lab Mock: 172.29.0.0/16)                       │
│                                                                                                   │
│   ┌───────────────────────────────────────────────────────────────────────────────────────────┐   │
│   │ WireGuard VPC Gateway (Hub)                                                               │   │
│   │   - Public Internet Interface (eth0): 172.28.0.2 (Production: Cloud EIP)                  │   │
│   │   - Private VPC Interface     (eth1): 172.29.0.2 (Production: 10.0.1.10)                  │   │
│   │   - Overlay Tunnel Interface  (wg0) : 10.100.0.1/24 (ListenPort: 51820/udp)               │   │
│   │   - Kernel: net.ipv4.ip_forward=1 + SNAT (iptables MASQUERADE -> eth1)                    │   │
│   └─────────────────────────────┬─────────────────────────────────┬───────────────────────────┘   │
│                                 │                                 │                               │
│                                 │ (Internal VPC Route / SNAT)     │                               │
│                                 ▼                                 ▼                               │
│   ┌─────────────────────────────────────────────┐   ┌─────────────────────────────────────────┐   │
│   │ Managed SaaS Services                       │   │ Kubernetes Cluster (Single-Zone)        │   │
│   │ - Databases (Redis: 172.29.0.20, Postgres)  │   │ - 10 nodes, single zone                 │   │
│   │ - Queues (Kafka, RabbitMQ)                  │   │ - Sample Workload (172.29.0.30:30080)   │   │
│   │ - Reachability: VPC private access only     │   │ - Internal Ingress / NodePort           │   │
│   └─────────────────────────────────────────────┘   └─────────────────────────────────────────┘   │
└─────────────────────────────────────────▲─────────────────────────────────────────────────────────┘
                                          │
                                          │ Encrypted WireGuard Overlay (UDP 51820)
                                          │ Public Internet Transit (Zero Peering / Interconnect)
                                          │ ChaCha20-Poly1305 Cipher | Clamped MTU 1420
                                          │
┌─────────────────────────────────────────┴─────────────────────────────────────────────────────────┐
│ Provider B (Bare-Metal Fleet: 30 Dedicated Servers)                                               │
│                                                                                                   │
│   ┌─────────────────────────┐     ┌─────────────────────────┐     ┌───────────────────────────┐   │
│   │ Bare-Metal Server 01    │     │ Bare-Metal Server 02    │     │ Bare-Metal Server 30      │   │
│   │  - eth0: Public IP      │     │  - eth0: Public IP      │     │  - eth0: Public IP        │   │
│   │  - wg0 : 10.100.0.10    │     │  - wg0 : 10.100.0.11    │ ... │  - wg0 : 10.100.0.39      │   │
│   │  - Route: VPC -> wg0    │     │  - Route: VPC -> wg0    │     │  - Route: VPC -> wg0      │   │
│   └────────────┬────────────┘     └────────────┬────────────┘     └─────────────┬─────────────┘   │
│                │                               │                                │                 │
│                └───────────────────────────────┴────────────────────────────────┘                 │
│                                (Outbound UDP 51820 Handshakes to Hub)                             │
│                                                                                                   │
│   * Firewall: 0 Inbound ports open on Bare Metal (Stateful conntrack handles returns)             │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘

```

### 1.2 Data Plane & Kernel Packet Flow

1. **Egress at Bare Metal:**
* Workload on `baremetal-01` opens a socket targeting Redis (`172.29.0.20:6379`) or Kubernetes (`172.29.0.30:30080`).
* The host route sends all `172.29.0.0/16` traffic to virtual device `wg0`.
* The kernel WireGuard driver matches `172.29.0.0/16` in its `AllowedIPs` routing table, encrypts the payload using ChaCha20-Poly1305, wraps it in UDP port 51820, and sends it via `eth0`.


2. **Stateful Traversal:**
* Provider B’s edge firewall sees an outbound UDP packet. Connection tracking (`conntrack`) permits replies without opening any inbound ports on Provider B.


3. **Ingress at Provider A Gateway:**
* Packet enters Gateway `eth0` on UDP port 51820. WireGuard decrypts the packet in-kernel and validates the sender’s public key against the internal IP allocation.


4. **SNAT & Delivery into VPC:**
* Kernel IP forwarding passes the decrypted packet to `eth1`.
* `iptables` applies SNAT (`MASQUERADE`), replacing the packet source IP with the gateway's VPC IP (`172.29.0.2`).
* SaaS Redis or Kubernetes receives the packet as coming from `172.29.0.2` and replies directly to it. The gateway de-NATs the reply, re-encrypts it, and returns it over the UDP tunnel.



### 1.3 Key Assumptions

* **CIDR Independence:** Provider A VPC (`172.29.0.0/16` in mock, `10.0.0.0/16` in production) and the WireGuard transit block (`10.100.0.0/16`) do not collide with local bare-metal subnets.
* **Single-Zone Limit:** Provider A cluster and SaaS services are pinned to a single availability zone.


* **Public Internet Transit:** Public internet allows UDP port 51820 between providers.
* **Team Capacity:** Operations are managed by 3 SREs alongside other engineering duties.




---

## Part 2: Hands-on Lab Simulation (Ubuntu + Podman)

This runbook creates the entire environment locally on an Ubuntu host using Podman, `kind`, and in-kernel WireGuard.

### Step 1: Install Host Prerequisites

Run on the Ubuntu host:

```bash
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

```

---

### Step 2: Create Isolated Networks & Strict Host Firewall

We simulate the public internet (`provider-b`, `172.28.0.0/16`) and the private VPC (`provider-a`, `172.29.0.0/16`), with iptables blocking direct routing on the host bridge layer.

```bash
# Clean up any leftover containers/networks
sudo podman rm -f baremetal-node vpc-gateway saas-redis provider-a-k8s-control-plane 2>/dev/null || true
sudo podman network rm provider-a provider-b 2>/dev/null || true
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s 2>/dev/null || true

# 1. Create simulated public internet network
sudo podman network create \
  --subnet 172.28.0.0/16 \
  --gateway 172.28.0.1 \
  -o "bridge=br-provider-b" \
  provider-b

# 2. Create simulated private VPC network
sudo podman network create \
  --subnet 172.29.0.0/16 \
  --gateway 172.29.0.1 \
  -o "bridge=br-provider-a" \
  provider-a

# 3. Block direct host forwarding between both bridges
sudo iptables -I FORWARD 1 -s 172.28.0.0/16 -d 172.29.0.0/16 -j DROP
sudo iptables -I FORWARD 2 -s 172.29.0.0/16 -d 172.28.0.0/16 -j DROP

```

---

### Step 3: Deploy SaaS Redis in Provider A (Private VPC)

Runs Redis on `172.29.0.20` with zero published host ports.

```bash
sudo podman run -d \
  --name saas-redis \
  --network provider-a \
  --ip 172.29.0.20 \
  --restart unless-stopped \
  docker.io/library/redis:7-alpine redis-server --protected-mode no

```

---

### Step 4: Deploy Kind Kubernetes Cluster & Sample App

Launch Kind using Podman, connect the control-plane container to `provider-a` at `172.29.0.30`, and expose a sample HTTP service via NodePort `30080`.

```bash
# 1. Create kind configuration
mkdir -p ~/wireguard-mock/k8s && cd ~/wireguard-mock
cat <<EOF > k8s/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    listenAddress: "0.0.0.0"
    protocol: TCP
EOF

# 2. Launch Kind using Podman provider
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --name provider-a-k8s --config k8s/kind-config.yaml

# 3. Export kubeconfig for root
export KUBECONFIG="$(sudo podman exec provider-a-k8s-control-plane cat /etc/kubernetes/admin.conf > /tmp/admin.conf && echo /tmp/admin.conf)"

# 4. Attach Kind node to Provider A private VPC network
sudo podman network connect --ip 172.29.0.30 provider-a provider-a-k8s-control-plane

# 5. Deploy sample workload exposed on NodePort 30080
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

# 6. Verify deployment readiness
sudo kubectl --kubeconfig=${KUBECONFIG} rollout status deployment/sample-workload --timeout=90s

```

---

### Step 5: Deploy the Dual-Homed Gateway & Bare-Metal Container

Deploy the gateway and bare-metal nodes with required Linux network capabilities (`--privileged`).

```bash
# 1. Launch VPC Gateway on provider-b (Public: 172.28.0.2)
sudo podman run -d \
  --name vpc-gateway \
  --network provider-b \
  --ip 172.28.0.2 \
  --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  docker.io/library/alpine:3.20 sleep infinity

# 2. Attach Gateway's second interface to provider-a (Private: 172.29.0.2)
sudo podman network connect --ip 172.29.0.2 provider-a vpc-gateway

# 3. Launch Bare-Metal Node on provider-b (Public: 172.28.0.100)
sudo podman run -d \
  --name baremetal-node \
  --network provider-b \
  --ip 172.28.0.100 \
  --privileged \
  docker.io/library/alpine:3.20 sleep infinity

# 4. Install networking and testing tools in both containers
sudo podman exec vpc-gateway apk add --no-cache wireguard-tools iptables iproute2
sudo podman exec baremetal-node apk add --no-cache wireguard-tools iptables iproute2 curl redis

```

---

### Step 6: Negative Test (Prove Strict Network Isolation)

Verify that the bare-metal container **cannot** reach the VPC resources before the WireGuard tunnel is configured:

```bash
echo -n "Test 1: Redis reachability (Must FAIL): "
if sudo podman exec baremetal-node nc -z -w 2 172.29.0.20 6379 2>/dev/null; then
  echo "FAILED: Redis is reachable! Isolation broken."
else
  echo "PASSED: Redis is unreachable (VPC is isolated)."
fi

echo -n "Test 2: K8s NodePort reachability (Must FAIL): "
if sudo podman exec baremetal-node nc -z -w 2 172.29.0.30 30080 2>/dev/null; then
  echo "FAILED: K8s is reachable! Isolation broken."
else
  echo "PASSED: K8s is unreachable."
fi

```

---

### Step 7: Configure and Activate WireGuard Tunnel

Generate keypairs, bind `wg0` interfaces, and apply gateway NAT rules.

```bash
# 1. Generate keys inside containers
sudo podman exec vpc-gateway sh -c "mkdir -p /etc/wireguard && wg genkey | tee /etc/wireguard/gw_priv.key | wg pubkey > /etc/wireguard/gw_pub.key"
sudo podman exec baremetal-node sh -c "mkdir -p /etc/wireguard && wg genkey | tee /etc/wireguard/bm_priv.key | wg pubkey > /etc/wireguard/bm_pub.key"

GW_PUB=$(sudo podman exec vpc-gateway cat /etc/wireguard/gw_pub.key)
BM_PUB=$(sudo podman exec baremetal-node cat /etc/wireguard/bm_pub.key)

# 2. Configure Gateway (Hub)
sudo podman exec vpc-gateway sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = \$(cat /etc/wireguard/gw_priv.key)

# SNAT outbound traffic leaving eth1 into Provider A VPC
PostUp = iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth1 -j MASQUERADE

[Peer]
# Bare-Metal Node 01
PublicKey = ${BM_PUB}
AllowedIPs = 10.100.0.10/32
EOF

wg-quick up wg0
"

# 3. Configure Bare-Metal Host (Spoke)
sudo podman exec baremetal-node sh -c "
cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.100.0.10/24
PrivateKey = \$(cat /etc/wireguard/bm_priv.key)

[Peer]
PublicKey = ${GW_PUB}
Endpoint = 172.28.0.2:51820
# Direct all VPC CIDR traffic into the tunnel
AllowedIPs = 172.29.0.0/16
PersistentKeepalive = 25
EOF

wg-quick up wg0
"

```

---

### Step 8: Positive End-to-End Verification

Verify encrypted reachability across the overlay:

#### 1. Check WireGuard Cryptokey State

```bash
sudo podman exec baremetal-node wg show

```

*(Confirms authenticated handshake and byte transfer counts)*

#### 2. Verify Managed SaaS Redis Access

```bash
# Ping test
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 ping
# Write & Read test
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 set srefleet:status "healthy"
sudo podman exec baremetal-node redis-cli -h 172.29.0.20 get srefleet:status

```

*Expected output: `PONG`, `OK`, `"healthy"*`

#### 3. Verify Kubernetes Core Workload Access

```bash
sudo podman exec baremetal-node curl -s http://172.29.0.30:30080

```

*Expected output:*

```text
HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard

```

---

### Step 9: Teardown Lab

```bash
sudo podman rm -f baremetal-node vpc-gateway saas-redis 2>/dev/null || true
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s 2>/dev/null || true
sudo podman network rm provider-a provider-b 2>/dev/null || true
sudo iptables -D FORWARD -s 172.28.0.0/16 -d 172.29.0.0/16 -j DROP 2>/dev/null || true
sudo iptables -D FORWARD -s 172.29.0.0/16 -d 172.28.0.0/16 -j DROP 2>/dev/null || true
rm -rf ~/wireguard-mock /tmp/admin.conf

```

---

## Part 3: Production Plan (Deliverable 3)

Everything the local mock leaves out, formatted as a prioritized implementation backlog:

### Prioritized Production Backlog

#### [P1] High Availability (HA) & Gateway Redundancy

* **Scope:** Deploy two WireGuard Gateway VMs across two different subnets in Provider A's VPC. Place them behind a Cloud Layer 4 Network Load Balancer (NLB) with a static Elastic IP health-checking UDP 51820.
* **Why Omitted from Mock:** The mock evaluates functional L3 routing convergence. Simulating active-passive VRRP/NLB failover on a single container host adds unnecessary moving parts for a local demo.



#### [P2] MTU Tuning & TCP MSS Clamping

* **Scope:** WireGuard adds 60 bytes of encapsulation overhead. Production bare-metal interfaces must pin `MTU = 1420`. The gateway must enforce MSS clamping to prevent PMTUD dropouts across intermediate transit providers:
```bash
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

```


* **Why Omitted from Mock:** Local Podman bridges run at MTU 1500 without multi-hop internet fragmentation.

#### [P3] Automated Provisioning via GitOps & `wg syncconf`

* **Scope:** When provisioning bare-metal node 31 via Ansible/cloud-init:
1. The node generates its keypair and records its public key in Git.
2. The CI/CD pipeline pushes the new peer configuration to the gateway.
3. The gateway executes `wg syncconf wg0 <(wg-quick strip wg0)`, adding the peer in-kernel without interrupting existing connections.


* **Why Omitted from Mock:** Manual key generation in the setup script sufficed for the 5-hour evaluation timebox.



#### [P4] Telemetry, Observability & Synthetic Health Probing

* **Scope:**
* Run `prometheus-wireguard-exporter` on gateways to scrape handshake latency and bandwidth.
* Configure alerts: `time() - wireguard_latest_handshake_seconds > 180` across all 30 nodes.


* Deploy Blackbox synthetic probes checking Redis and Kubernetes endpoints every 10 seconds.


* **Why Omitted from Mock:** Container exit statuses and CLI verification validated functional criteria.



#### [P5] Defense-in-Depth Firewall & Egress Policies

* **Scope:** Replace open SNAT with strict destination filtering: allow only Redis (`6379/tcp`) and Kubernetes Ingress (`443/tcp`, `30080/tcp`). Drop all arbitrary VPC subnet scanning attempts.
* **Why Omitted from Mock:** Broad SNAT allowed immediate validation of multiple workload types simultaneously.



---

### Deliberately Deferred Choices & Revisit Triggers

1. **Self-Hosted Headscale / Tailscale Subnet Router:**
* *Rationale:* Headscale adds an external coordination daemon, SQLite/PostgreSQL persistence, and TLS certificate renewal to maintenance routines. For a static fleet of 30 bare-metal servers, this increases operational overhead beyond what a 3-person team needs.


* *Revisit Trigger:* Revisit if the bare-metal fleet grows beyond 150–200 nodes, or requires dynamic peer-to-peer mesh connectivity between bare-metal nodes rather than centralized VPC ingress.




2. **BGP Anycast Routing:**
* *Rationale:* Provider A's Kubernetes cluster and SaaS services are fixed to a single zone. If Provider A suffers an outage, the underlying database and compute are unavailable. Routing packets to another geographic point via BGP Anycast provides zero failover value.


* *Revisit Trigger:* Revisit only if Provider A expands into an active-active, multi-region database architecture with cross-region replication.
