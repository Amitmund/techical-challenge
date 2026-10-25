### Data Plane & Kernel Mechanics
- **In-Kernel Cryptokey Routing:** WireGuard runs directly in the Linux kernel space. It binds cryptographic public keys directly to IP prefixes (`AllowedIPs`).
- **Stateless SNAT:** Decrypted packets exiting `wg0` targeting `172.29.0.0/16` are masqueraded behind the gateway's VPC IP (`172.29.0.2`). SaaS services and Kubernetes reply naturally to the gateway on the local VPC subnet without requiring custom VPC routing tables or complex return-path routing.
- **Outbound-Initiated Statefulness:** Bare-metal hosts initiate UDP handshakes outbound. Stateful firewalls in Provider B maintain `conntrack` tables, requiring **zero open inbound ports** on bare-metal servers. The gateway only exposes one UDP port (`51820`).

---

## 2. Assumptions

1. **VPC Addressing:** Provider A VPC operates on a non-overlapping private CIDR block (`172.29.0.0/16` in mock, `10.0.0.0/16` in production). Bare-metal nodes do not overlap with this CIDR.
2. **Fixed Cloud Constraints:** Provider A's Kubernetes cluster and SaaS services are strictly single-zone; no cloud-provider interconnect or direct peering is purchasable or permitted.
3. **Small SRE Team:** An operations team of 3 engineers manages this setup alongside standard duties; solutions requiring heavy distributed state or proprietary daemons are out of scope.
4. **Transport:** Internet transit between Provider A and B supports standard UDP traffic. MTU over internet transit defaults to ~1500 bytes.

---

## 3. Technology Choices & Evaluation

| Solution | Operational Overhead (3 SREs) | Performance / Throughput | Reliability & Simplicity | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| **IPsec (strongSwan)** | High (IKEv2 daemon, complex SA rekeys, DPD flakiness) | Moderate | Fragile configuration surface | **Rejected** |
| **L7 Reverse Proxy (FRP / Pangolin / Rathole)** | Moderate | Low (Userspace multiplexing, head-of-line blocking) | Breaks dynamic DB/queue cluster discovery | **Rejected** |
| **Tailscale / Headscale (Mesh Overlay)** | Moderate (Requires hosting coordination DB, coordination daemon, TLS certs) | High | Adds control plane failure domain for 30 static nodes | **Rejected** |
| **Pure WireGuard Hub-and-Spoke** | Very Low (In-kernel, zero daemons, static 50-line config) | Maximum (Near line-rate, in-kernel ChaCha20-Poly1305) | Robust, auditable, native Linux primitives | **Selected** |

---

## 4. Scalability & Extensibility

- **Horizontal Subnet Allocation:**
  - `10.100.10.0/24`: Provider B Bare-Metal Fleet (Node 1..30).
  - `10.100.20.0/24`: Provider C Bare-Metal Fleet (Future expansion).
  - `10.100.1.0/24`: Transit Gateway for Secondary Cloud Provider X.
- **Zero-Downtime Dynamic Scaling (`wg syncconf`):**
  Adding node 31 does not require restarting the gateway or dropping existing connections. Ansible/GitOps pushes the updated config and runs:
  `wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)`
  The kernel updates the peer table in memory with zero connection disruption.

---

## 5. Risks & Mitigation

1. **Gateway as Single Point of Failure (SPOF):**
   - *Risk:* If the single gateway node crashes, all 30 bare-metal servers lose VPC access.
   - *Mitigation:* In production, deploy an Active/Passive gateway pair across two subnets behind an AWS/GCP Layer 4 Network Load Balancer (NLB) with UDP health checks.
2. **MTU / PMTUD Blackholes:**
   - *Risk:* WireGuard adds 60-byte overhead (IPv4 + UDP + WG). 1500-byte packets exceed transit MTU and get dropped silently if ICMP Fragmentation Needed is blocked.
   - *Mitigation:* Pin `MTU = 1420` on all WireGuard interfaces and enforce TCP MSS clamping:
     `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`.
3. **Subnet Routing Leaks:**
   - *Risk:* Misconfigured `AllowedIPs` could route all bare-metal internet traffic through Provider A.
   - *Mitigation:* Explicitly whitelist only the VPC CIDR (`172.29.0.0/16`) in `AllowedIPs`.

---

## 6. How We Would Get It Into Production

1. **Phase 1 (Terraform/IaC):** Provision a dual-homed EC2/GCE gateway instance with Elastic IP, Security Groups allowing UDP 51820 inbound, and IAM roles.
2. **Phase 2 (Ansible/GitOps):** Deploy gateway WireGuard configuration and enable IP forwarding + SNAT. Deploy WireGuard to 1 canary bare-metal server in Provider B.
3. **Phase 3 (Canary Verification):** Validate end-to-end database latency, connection pooling, and MTU limits from the canary node.
4. **Phase 4 (Fleet Rollout):** Run Ansible playbook across the remaining 29 bare-metal servers. Execute `wg syncconf` on the gateway.
5. **Phase 5 (Monitoring & Cutover):** Attach Prometheus exporter, configure synthetic canary probes, and switch application database connection strings to the private VPC endpoints.
"""

# 10. PRODUCTION_PLAN.md
production_plan_content = """# Deliverable 3: Production Plan

A prioritized engineering roadmap detailing operational aspects omitted from the local mock, along with architectural trade-offs and revisit triggers.

---

## Prioritized To-Do List

### [P1] High Availability (HA) & Gateway Redundancy
- **What it is:** Deploy an Active/Passive or Dual-Active WireGuard gateway pair behind a Cloud Layer 4 Network Load Balancer (NLB) with a static Elastic IP.
- **Why omitted from mock:** The mock focuses on core L3 reachability. Simulating multi-node VRRP/Keepalived inside single-host Docker creates artificial complexity for a proof-of-concept.
- **Action items:**
  1. Deploy 2x Gateway VMs across two separate subnets in Provider A VPC.
  2. Configure Cloud NLB targeting UDP 51820 on both instances.
  3. Implement Keepalived or NLB health-check responder script.

### [P2] MTU Tuning & TCP MSS Clamping
- **What it is:** WireGuard encapsulates packets with 60 bytes of overhead (IPv4: 20B, UDP: 8B, WireGuard: 32B). Unclamped TCP connections experience silent drops and latency degradation over public internet transit.
- **Why omitted from mock:** Local Docker/Podman bridge networks default to 1500 MTU without multi-hop ISP fragmentation.
- **Action items:**
  1. Pin `MTU = 1420` on all bare-metal `wg0` interfaces.
  2. Apply iptables MSS clamping on the gateway:
     `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`.

### [P3] Automated Provisioning via GitOps & `wg syncconf`
- **What it is:** Completely automate peer key generation, IP assignment, and gateway registration using Ansible and GitOps.
- **Why omitted from mock:** Replaced with a shell loop in setup scripts to respect the 5-hour mock timebox.
- **Action items:**
  1. Define bare-metal fleet declarative inventory in Git (`inventory/peers.yaml`).
  2. Implement cloud-init script for bare-metal bootstrapping (generates private key, commits public key to repo).
  3. Deploy CI/CD pipeline to run `wg syncconf wg0 <(wg-quick strip wg0)` on the gateway on peer additions.

### [P4] Telemetry, Observability & Synthetic Health Probing
- **What it is:** Export WireGuard metrics to Prometheus and alert on tunnel degradation.
- **Why omitted from mock:** Standard container health checks and CLI verification sufficed for the local demo.
- **Action items:**
  1. Deploy `prometheus-wireguard-exporter` on gateways.
  2. Create alert: `time() - wireguard_latest_handshake_seconds > 180` for any peer.
  3. Deploy Blackbox exporter on bare metal to probe Redis and K8s endpoints every 10 seconds.

### [P5] Defense-in-Depth Firewall & Egress Policies
- **What it is:** Restrict bare-metal access exclusively to approved destination ports rather than open VPC access.
- **Why omitted from mock:** Open SNAT was used to prove generalized L3 reachability across both workloads.
- **Action items:**
  1. Restrict forward rules: Allow only Redis (`6379/tcp`) and K8s Ingress/NodePort (`30080/tcp`, `443/tcp`).
  2. Block arbitrary VPC port scanning from bare-metal nodes.

---

## What We Deliberately Chose NOT to Build

### 1. Tailscale / Headscale Coordination Server
- **Rationale:** Headscale introduces an external coordination daemon, SQLite/PostgreSQL database state, TLS certificate management, and an additional control-plane failure domain. For a small fleet of 30 static bare-metal servers, this violates the 3-person SRE team operational constraint.
- **Revisit Trigger:** If the bare-metal fleet grows past 150–200 nodes, or if bare-metal workloads require dynamic peer-to-peer mesh connectivity between themselves rather than simple hub-and-spoke VPC access.

### 2. BGP Anycast Ingress
- **Rationale:** The prompt explicitly states Provider A's cluster is single-zone and managed SaaS services reside strictly in that VPC. If the zone or cloud provider fails, the data and compute are unreachable; BGP Anycast routing packets to an alternate dead location provides zero availability value.
- **Revisit Trigger:** Revisit only if Provider A expands into an active-active multi-region database architecture with multi-cluster replication.
"""

# 11. README.md
readme_content = """# WireGuard VPC Bridge: Bare-Metal to Cloud VPC Interconnect

This repository provides a reproducible, production-grade mock implementation for securely connecting 30 bare-metal servers (Provider B) to an isolated cloud VPC (Provider A) hosting managed SaaS services (Redis) and a Kubernetes cluster (`kind`), running locally on Ubuntu using Podman and kernel WireGuard.

---

## Architecture Topology
