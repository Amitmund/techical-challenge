

### 1. Network Placement & Routing Architecture

#### Lab Simulation Approach

* A dual-homed container placed on `provider-b` (`eth0`) and `provider-a` (`eth1`).
* Unconditional SNAT (`iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE`) rewrites all traffic leaving the gateway into the VPC.

#### Production Implementation

* **Gateway Location:** The WireGuard gateway runs as an EC2/Compute instance provisioned inside **Provider A's public subnet**, equipped with a single Elastic Network Interface (ENI) and a public Elastic IP (EIP) attached through the VPC Internet Gateway (IGW).
* **SNAT vs. Native VPC Routing:**
* **Option A: Native VPC Route Table (Recommended for Auditability):**
Disable Source/Destination Check on the Gateway instance (`aws ec2 modify-instance-attribute --no-source-dest-check`). In the VPC route table, add a route:
```text
10.100.0.0/24 -> eni-0123456789abcdef0 (Gateway ENI)

```


*Advantage:* Removes SNAT. Backend services (Redis, Kubernetes) see the actual client IP (`10.100.0.10`), which preserves audit logs, rate-limiting, and network policies.
* **Option B: Gateway SNAT (Used when Cloud Route Tables are Inaccessible):**
If the SRE team lacks IAM permissions to modify VPC route tables, the gateway must continue performing SNAT. However, replace broad MASQUERADE with an explicit SNAT target:
```bash
iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o eth0 -j SNAT --to-source 10.0.1.10

```





---

### 2. High Availability (HA) & Fault Tolerance

#### Lab Simulation Approach

* A single container (`vpc-gateway`). If it stops, the entire overlay drops.

#### Production Implementation

For 30 bare-metal servers processing production workloads, a single gateway VM is an unacceptable Single Point of Failure (SPOF).

* **Dual Gateway Topology:** Deploy two gateway instances across two different Availability Zones:
* `gw-az1.provider-a.net` (Private IP: `10.0.1.10`, Overlay IP: `10.100.0.1`)
* `gw-az2.provider-a.net` (Private IP: `10.0.2.10`, Overlay IP: `10.100.0.2`)


* **Failover Mechanism Options:**
1. **Cloud L4 Network Load Balancer (NLB):** Place both gateways behind an active-active UDP NLB. Note that because WireGuard is connectionless and stateful UDP sessions can break across multiple backends, configure target groups with client IP stickiness and UDP health probes checking a sidecar HTTP/TCP daemon.
2. **Active-Passive VRRP with Cloud Route Takeover:** Run `keepalived` between the two gateways. Upon master failure, the backup promotes itself and calls the Cloud CLI/API to repoint the VPC route table entry (`10.100.0.0/24 -> eni-gateway-02`) and reassign the public EIP.
3. **Multi-Peer Client Routing:** On the 30 bare-metal nodes, configure **two** `[Peer]` blocks in `wg0.conf`: one for Hub 1 and one for Hub 2, dynamically selecting routes or leveraging BFD/FRRouting (BGP over WireGuard) for sub-second convergence.



---

### 3. MTU Engineering & TCP MSS Clamping

#### Lab Simulation Approach

* The virtual bridge uses standard MTU 1500 without fragmentation.

#### Production Implementation

WireGuard adds fixed protocol encapsulation overhead to every packet:

* Standard IPv4 header: 20 bytes
* UDP header: 8 bytes
* WireGuard header: 32 bytes
* **Total Overhead:** 60 bytes (80 bytes if intermediate transit uses IPv6).

If bare-metal servers send standard 1500-byte packets, the encapsulated UDP packet reaches 1560 bytes. Because public internet transit points (and cloud provider underlays) drop packets greater than 1500 bytes and often drop ICMP "Fragmentation Needed" messages (Path MTU Discovery Blackhole), connections hang on large TLS handshakes or large HTTP responses.

* **Fix 1: Pin Interface MTU on Bare-Metal:**
```text
[Interface]
MTU = 1420

```


*(If intermediate networks use PPPoE or cloud overlay fabrics like Geneve/VXLAN, drop to `1360`)*.
* **Fix 2: Enforce TCP MSS Clamping on the Gateway:**
Enforce clamping in `iptables` on the Gateway to guarantee the outer packet never exceeds 1500 bytes:
```bash
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

```



---

### 4. Fleet Provisioning & GitOps (`wg syncconf`)

#### Lab Simulation Approach

* Keys were generated manually via `wg genkey` inside test containers, and `wg-quick down/up` was executed to reload configs.

#### Production Implementation

Restarting `wg-quick down/up` in production flushes existing connection states and drops in-flight database transactions across all 30 servers.

* **Zero-Downtime Dynamic Reconfiguration:**
When provisioning a new bare-metal server (Node 31):
1. The new node provisions its keypair during cloud-init/Ansible bootstrapping and sends its public key to a central repository (or Vault).
2. The gateway's Ansible playbook or GitOps runner renders the new `/etc/wireguard/wg0.conf`.
3. The gateway applies the update in-kernel **without dropping existing peers** using `wg syncconf`:
```bash
wg syncconf wg0 <(wg-quick strip wg0)

```




* **Configuration Management Layout (Ansible / Terraform):**
Maintain peer mappings in a single structured YAML inventory:
```yaml
wireguard_peers:
  - name: baremetal-01
    pubkey: "abcd1234..."
    allowed_ip: "10.100.0.10/32"
  - name: baremetal-02
    pubkey: "efgh5678..."
    allowed_ip: "10.100.0.11/32"

```



---

### 5. Split-Horizon DNS & Name Resolution

#### Lab Simulation Approach

* Hardcoded direct private IPs (`172.29.0.20`, `172.29.0.30`).

#### Production Implementation

Bare-metal workloads should never connect to raw cloud IPs; they must resolve internal cloud hostnames (e.g., `redis.prod.provider-a.internal`, `k8s.prod.provider-a.internal`).

* **The Problem:** In a split-tunnel setup, setting `DNS = 10.0.0.2` (VPC Route 53 / CoreDNS) in WireGuard rewrites `/etc/resolv.conf`, sending all public bare-metal DNS traffic through the tunnel.
* **The Solution (Conditional Split-DNS):**
Configure `systemd-resolved` on the bare-metal fleet to route queries conditionally based on search domain:
```bash
resolvectl dns wg0 10.0.0.2
resolvectl domain wg0 ~provider-a.internal ~10.in-addr.arpa

```


*Result:* Queries for `*.provider-a.internal` route securely through `wg0` to Provider A's private DNS resolvers, while public lookups (`github.com`, `ubuntu.com`, public APIs) continue using the bare-metal server's native resolvers without latency overhead.

---

### 6. Defense-in-Depth & Zero-Trust Egress Filtering

#### Lab Simulation Approach

* Open `MASQUERADE` on the Gateway; any packet passing through the tunnel can access the entire `172.29.0.0/16` subnet on any port.

#### Production Implementation

A compromised bare-metal server must not have unrestricted network reconnaissance access across the VPC.

* **Stateful Egress Firewall Rules on Gateway:**
Enforce strict destination port filtering in the `FORWARD` chain of the gateway:
```bash
# Allow established connections
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Restrict bare-metal traffic to explicit destinations and ports
# 1. Managed Redis (10.0.5.20:6379)
iptables -A FORWARD -s 10.100.0.0/24 -d 10.0.5.20/32 -p tcp --dport 6379 -j ACCEPT

# 2. Kubernetes Ingress Controllers (10.0.10.0/24 on 443 and 8443)
iptables -A FORWARD -s 10.100.0.0/24 -d 10.0.10.0/24 -p tcp -m multiport --dports 443,8443 -j ACCEPT

# Drop all arbitrary VPC subnet scanning, SSH attempts, and metadata access
iptables -A FORWARD -s 10.100.0.0/24 -d 10.0.0.0/16 -j DROP

```


* **Post-Quantum Cryptographic Hardening (PresharedKey):**
Generate a symmetrical pre-shared key (PSK) between the gateway and each bare-metal server to add quantum-resistant protection:
```bash
wg genpsk > /etc/wireguard/peer.psk

```


Include `PresharedKey = ...` in the `[Peer]` sections of both Hub and Spoke.

---

### 7. Telemetry, Observability & Synthetic Probing

#### Lab Simulation Approach

* Ad-hoc manual CLI checks (`wg show`, `redis-cli ping`, `curl`).

#### Production Implementation

Automated 24/7 observability is required across a 30-node production fleet.

* **Prometheus WireGuard Exporter:**
Run `prometheus-wireguard-exporter` as a systemd service on all gateways and bare-metal nodes to scrape kernel stats directly.
* *Critical Metrics:*
* `wireguard_latest_handshake_seconds`: Timestamp of the last Noise handshake.
* `wireguard_sent_bytes_total` / `wireguard_received_bytes_total`: Traffic volume.




* **Prometheus Alerting Rules:**
Alert SREs before applications fail if handshakes stall:
```yaml
- alert: WireGuardHandshakeStale
  expr: (time() - wireguard_latest_handshake_seconds) > 180
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "WireGuard tunnel to {{ $labels.peer }} has stalled."
    description: "No authenticated handshake for over 3 minutes. Network path interrupted."

```


* **Synthetic Probing (Prometheus Blackbox Exporter):**
Run continuous synthetic checks from the bare-metal fleet targeting the private VPC endpoints every 10 seconds:
* TCP Connect probe targeting Redis (`10.0.5.20:6379`).
* HTTP GET probe targeting Kubernetes Health Endpoint (`[https://ingress.provider-a.internal/healthz](https://ingress.provider-a.internal/healthz)`).
