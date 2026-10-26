In Podman (and container networking in general), **`bridge`** is only one of several network drivers and modes. Each driver uses different Linux kernel primitives to connect containers to each other, to the host, and to the external network.

---

### Podman Network Drivers and Modes

| Driver / Mode | Kernel Primitive | L2 (MAC Address) | L3 (IP Routing & Subnet) | Primary Use Case |
| --- | --- | --- | --- | --- |
| **`bridge`** *(Default)* | `veth` pair + Linux bridge + `iptables`/`nftables` | Containers get virtual MACs on an internal software switch. | Private virtual CIDR; NAT/masquerade to reach outside. | Multi-container apps on a single host; isolated topologies (like our mock). |
| **`macvlan`** | Kernel `macvlan` module on a parent physical interface (`eth0`) | Every container gets its own **unique physical-looking MAC address**. | Placed directly on the physical/underlay LAN subnet (e.g., your home/office router assigns the IP via DHCP). | Low latency; making containers look like real physical servers on the physical LAN. |
| **`ipvlan`** (L2 / L3) | Kernel `ipvlan` module on a parent interface | Containers **share the host's MAC address**. | **L2:** Same subnet as parent interface.<br><br>**L3:** Different subnets routed without ARP broadcast. | High-density setups where network switches drop or throttle multiple MAC addresses per port (e.g., cloud VMs). |
| **`host`** | None (no network namespace created) | Uses the host's physical network stack and MAC. | Uses the host's IP and port space directly. | Line-rate performance with zero virtualization overhead; services that need all host ports. |
| **`none`** | Isolated network namespace with only `lo` (loopback) | None. | No external routing. | Air-gapped batch jobs, offline cryptographic operations. |
| **`container:<id>`** | Shares existing network namespace | Shares MAC with target container. | Shares IP and localhost loopback with target container. | Sidecar patterns (like Kubernetes Pod containers sharing `localhost`). |
| **`pasta` / `slirp4netns**` | User-space TCP/IP stack (`/dev/net/tun`) | Emulated in user space. | User-space NAT without root privileges. | Rootless Podman when non-root users cannot manage kernel bridges. |

---

### How They Differ Under the Hood

#### 1. `bridge` (What we are using)

```
[ Container A ]           [ Container B ]
    (vethA)                   (vethB)
       │                         │
       └───────────┬─────────────┘
                   ▼
          [ Linux Bridge (podman1) ]
                   │
           (iptables NAT/SNAT)
                   ▼
         [ Host eth0 / Kernel ]

```

* **Pros:** Completely isolated, custom IP address ranges (e.g., `172.28.0.0/16`, `172.29.0.0/16`), easy to simulate multi-cloud routing and firewall drops on one machine.
* **Cons:** Incurs bridge traversal and NAT overhead.

---

#### 2. `macvlan`

```
           [ Physical Switch / Router ]
                        │
         ┌──────────────┴──────────────┐
         ▼                             ▼
   [ Host eth0 ]             [ Container eth0 ]
  (MAC: AA:BB:CC)           (MAC: DD:EE:FF)
  IP: 192.168.1.50          IP: 192.168.1.120 (Direct on LAN)

```

* Creates virtual sub-interfaces directly attached to the physical NIC (`eth0`).
* **Kernel Caveat:** By design, the Linux kernel does not allow the host to talk directly to its own child `macvlan` interfaces without a dedicated bridge shim.
* Command to create:
```bash
sudo podman network create -d macvlan -o parent=eth0 --subnet 192.168.1.0/24 my-macvlan

```



---

#### 3. `ipvlan`

* Similar to `macvlan`, but all containers share the parent interface’s single MAC address.
* **Why it exists:** Cloud providers (like AWS, Azure, GCP, or strict enterprise switches) enforce MAC-spoofing protection and drop packets from unknown MACs. `macvlan` breaks in those environments; `ipvlan` works because the MAC never changes.
* Command to create:
```bash
sudo podman network create -d ipvlan -o parent=eth0 --subnet 192.168.1.0/24 my-ipvlan

```



---

### Why `bridge` is Specifically Required for Our WireGuard Mock

For the SRE technical challenge, **`bridge`** is the only driver that works for the local lab:

1. **Multi-Subnet Simulation:** We need two entirely separate non-physical CIDR blocks (`172.28.0.0/16` and `172.29.0.0/16`) running on a single host. `macvlan` and `ipvlan` depend on attaching to real physical interfaces and subnets.
2. **Artificial Isolation:** We must simulate unpeered clouds using host `iptables` drop rules between the two bridges.
3. **Gateway Routing:** The `vpc-gateway` container attaches two virtual interfaces (`eth0` on `provider-b` and `eth1` on `provider-a`), acting as an in-kernel router between the two virtual networks.







---



In virtualization platforms like VirtualBox and VMware Workstation/ESXi, networking is categorized into distinct modes based on whether VMs can talk to the host, each other, the local physical LAN, or the outside internet.

Here is how those hypervisor network modes work, what they do under the hood, and their direct equivalents in the Linux container world.

---

### The Hypervisor Networking Modes

#### 1. NAT (Simple / Per-VM)

* **What it does:** The hypervisor runs an isolated user-space routing engine and DHCP service for that specific VM (often giving it `10.0.2.15`).
* **Traffic Flow:** The VM can reach the internet (hypervisor rewrites packets using the host’s IP), but the host cannot reach the VM without explicit port forwarding rules.
* **Inter-VM:** VMs configured with standard NAT **cannot** talk to each other, because each VM is trapped in its own isolated user-space NAT bubble.
* **Container Equivalent:** **Rootless Podman (`slirp4netns` / `pasta`)**. It runs an unprivileged TCP/IP stack in user-space without creating real kernel bridge interfaces.

#### 2. NAT Network (VirtualBox) / NAT Virtual Switch (VMware `vmnet8`)

* **What it does:** Creates an internal virtual switch with a shared DHCP server and a shared NAT gateway.
* **Traffic Flow:** All VMs connected to this network receive IPs on the same subnet (e.g., `192.168.100.0/24`), can talk directly to each other at Layer 2/3, and can reach the external internet via the host's outbound NAT.
* **Container Equivalent:** **Podman / Docker default `bridge` network** (what we just created). Containers connect via virtual cables (`veth` pairs) to a shared virtual switch (`br-provider-a`), and outbound packets are translated using Linux kernel `iptables` `MASQUERADE`.

#### 3. Bridged Adapter (Bridged Networking / VMware `vmnet0`)

* **What it does:** Attaches the VM’s virtual NIC directly to the host’s physical Ethernet or Wi-Fi card at Layer 2.
* **Traffic Flow:** The VM appears as an independent physical machine on your home or office local network. It requests an IP directly from your physical Wi-Fi router or office DHCP server (e.g., `192.168.1.150`).
* **Container Equivalent:** **`macvlan`** (gives the container its own MAC address on the host's physical NIC) or attaching a container's `veth` to a pre-existing host Linux bridge (`br0`).

#### 4. Host-Only (VirtualBox `vboxnet0` / VMware `vmnet1`)

* **What it does:** Creates a private virtual switch that only connects the host OS and the VMs on that switch.
* **Traffic Flow:** The host can ping and SSH into the VMs, and VMs can talk to each other. However, there is **zero gateway to the physical internet**. The VMs are completely isolated from the outside world.
* **Container Equivalent:** A Podman `bridge` where default gateway routing and outbound `iptables` NAT rules are disabled, but the host maintains its IP on the bridge interface.

#### 5. Internal Network (VirtualBox) / Private Switch (VMware isolated LAN segment)

* **What it does:** Connects VMs together on a completely isolated software bus.
* **Traffic Flow:** The VMs can talk **only** to other VMs on that exact same internal segment. The host OS does not even get an IP address or interface on this network, and there is zero internet access.
* **Container Equivalent:** A private bridge network where host IP forwarding is blocked, no gateway IP is assigned, and external routing chains are set to `DROP`.

---

### Hypervisor vs. Container Networking Rosetta Stone

| Hypervisor Mode (VMware / VirtualBox) | Container Equivalent (Podman / Linux) | Can VM/Container reach Internet? | Can Host reach VM/Container directly? | Can VMs/Containers talk to each other? |
| --- | --- | --- | --- | --- |
| **NAT (Individual)** | `slirp4netns` / `pasta` (Rootless) | Yes (via Host IP) | No (requires port forward) | No |
| **NAT Network** | `bridge` (Standard Rootful) | Yes (via `MASQUERADE`) | Yes (via bridge gateway IP) | Yes (on same network) |
| **Bridged** | `macvlan` | Yes (directly via LAN router) | Yes (LAN routing) | Yes (as peers on LAN) |
| **Host-Only** | `bridge` (without outbound NAT) | No | Yes | Yes |
| **Internal Network** | Isolated bridge / Network Namespace | No | No (host has no IP/route) | Yes (only peers on switch) |

---

### How This Maps to Our WireGuard Architecture

What we built with Podman in the lab is the exact equivalent of how network architects build test topologies in VMware or VirtualBox:

1. **`provider-a` and `provider-b**` are behaving like two distinct **Internal Networks / Private Virtual Switches**.
2. Normally, Podman bridges act like **NAT Networks** (letting packets route across bridges or out to the internet).
3. By adding our explicit `iptables -I FORWARD ... -j DROP` rules, we severed the default routing between those switches, turning them into strictly isolated network segments.
4. The **`vpc-gateway` container** is the equivalent of a multi-homed VM with two virtual network cards (one plugged into the "Provider B" switch and one plugged into the "Provider A" switch), running routing and WireGuard to bridge the divide securely.
