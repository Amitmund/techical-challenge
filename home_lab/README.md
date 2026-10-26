┌───────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Provider A                                                                                        │
│                                                                                                   │
│  ┌─ VPC Private Network (Production: 10.0.0.0/16 | Local Mock: 172.29.0.0/16) ──────────────────┐  │
│  │                                                                                              │  │
│  │   ┌───────────────────────────────────────────────────────────────────────────────────────┐  │  │
│  │   │ WireGuard VPC Gateway (Hub)                                                           │  │  │
│  │   │   - Public Internet Interface (eth0): Elastic IP / 172.28.0.2                         │  │  │
│  │   │   - Private VPC Interface     (eth1): 10.0.1.10  / 172.29.0.2                         │  │  │
│  │   │   - Overlay Tunnel Interface  (wg0) : 10.100.0.1/24 (ListenPort: 51820/udp)           │  │  │
│  │   │   - Kernel: IP Forwarding (net.ipv4.ip_forward=1) + SNAT (iptables MASQUERADE -> eth1)│  │  │
│  │   └───────────────────────────────┬───────────────────────────────────┬───────────────────┘  │  │
│  │                                   │                                   │                      │  │
│  │                                   │ (Internal VPC Route / SNAT)       │                      │  │
│  │                                   ▼                                   ▼                      │  │
│  │   ┌───────────────────────────────────────────────┐   ┌───────────────────────────────────┐  │  │
│  │   │ Managed SaaS Services                         │   │ Kubernetes Cluster                │  │  │
│  │   │ - Databases (Postgres, Redis: 172.29.0.20)    │   │ - 10 nodes, single zone           │  │  │
│  │   │ - Message Queues (Kafka, RabbitMQ)            │   │ - Internal Ingress / NodePort     │  │  │
│  │   │ - Reachability: VPC private access only       │   │ - Core Services (172.29.0.30:30080│  │  │
│  │   └───────────────────────────────────────────────┘   └───────────────────────────────────┘  │  │
│  │                                                                                              │  │
│  └──────────────────────────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────▲───────────────────────────────────────────────────┘
                                                │
                                                │  Encrypted WireGuard Overlay (UDP 51820)
                                                │  Public Internet Transit (Zero Peering/Interconnect)
                                                │  ChaCha20-Poly1305 Cipher | MTU 1420
                                                │
┌───────────────────────────────────────────────┴───────────────────────────────────────────────────┐
│ Provider B                                                                                        │
│                                                                                                   │
│  ┌─ Bare-Metal Fleet (Main Workloads) ──────────────────────────────────────────────────────────┐  │
│  │                                                                                              │  │
│  │   ┌───────────────────────────┐    ┌───────────────────────────┐    ┌─────────────────────┐  │  │
│  │   │ Bare-Metal Server 01      │    │ Bare-Metal Server 02      │    │ Bare-Metal Server 30│  │  │
│  │   │   - eth0: Public IP       │    │   - eth0: Public IP       │    │   - eth0: Public IP │  │  │
│  │   │   - wg0 : 10.100.0.10     │    │   - wg0 : 10.100.0.11     │... │   - wg0 : 10.100.0.39│  │
│  │   │   - Route: VPC CIDR -> wg0│    │   - Route: VPC CIDR -> wg0│    │   - Route: VPC -> wg0  │  │
│  │   └─────────────┬─────────────┘    └─────────────┬─────────────┘    └──────────┬──────────┘  │  │
│  │                 │                                │                             │             │  │
│  │                 └────────────────────────────────┴─────────────────────────────┘             │  │
│  │                               (Outbound-Only UDP Handshakes to Hub)                          │  │
│  │                                                                                              │  │
│  │   * Firewalls: Zero inbound open ports required on bare-metal (Stateful conntrack returns)   │  │
│  └──────────────────────────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
