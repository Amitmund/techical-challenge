

can deploy a dedicated Site-to-Site Egress Gateway (an outbound router/proxy host) in Provider B. This shifts the architecture from a Host-to-Site (Hub-and-Spoke) model to a Site-to-Site Tunnel, eliminating the need to install WireGuard, manage kernel modules, or distribute cryptographic keypairs across the 30 bare-metal servers.

### How the Site-to-Site Egress Gateway Works
Instead of running WireGuard on every workload server, you place a dedicated Linux instance (e.g., egress-gateway-b) on Provider B's local network alongside the 30 bare-metal servers.


```
┌──────────────────────────────────────────────────────────────────┐
│ Provider B (Bare-Metal Local LAN: 192.168.1.0/24)                 │
│                                                                  │
│  [ Bare-Metal 01 ] ... [ Bare-Metal 30 ]                         │
│    192.168.1.10          192.168.1.39                            │
│    (No WireGuard installed!)                                     │
│         │                     │                                  │
│         └──────────┬──────────┘                                  │
│                    │ Target: 10.0.0.0/16 (VPC)                   │
│                    ▼                                             │
│       [ egress-gateway-b ] (192.168.1.254)                       │
│         - eth0: Local LAN (192.168.1.254)                        │
│         - eth1: Public IP                                        │
│         - wg0 : 10.100.0.2                                       │
│         - Kernel: net.ipv4.ip_forward=1                          │
└────────────────────┬─────────────────────────────────────────────┘
                     │
                     │ Encrypted WireGuard (Site-to-Site UDP 51820)
                     ▼
┌────────────────────┴─────────────────────────────────────────────┐
│ Provider A (VPC Gateway Hub: 10.100.0.1)                         │
│                                                                  │
│  [ vpc-gateway-a ] ──────► [ Redis / K8s Core Services ]         │
└──────────────────────────────────────────────────────────────────┘
```
