# docker -o "bridge" vs Podman Netavark

This error occurs because Ubuntu's Podman uses Netavark as its network backend. Unlike Docker (which accepts custom bridge name options), Netavark manages bridge devices automatically and rejects -o "bridge=..." as an unsupported driver option.

Because our iptables isolation rules and container bindings are based on subnets (172.28.0.0/16 and 172.29.0.0/16), we do not need custom bridge interface names. Podman will automatically instantiate bridge devices (typically named podman1, podman2, etc.) and bind the gateway IPs to them.

The Fix

Remove the -o "bridge=..." flag when creating both networks:

```
Bash
# 1. Create simulated public internet network (Provider B)
sudo podman network create \
  --subnet 172.28.0.0/16 \
  --gateway 172.28.0.1 \
  provider-b

# 2. Create simulated private VPC network (Provider A)
sudo podman network create \
  --subnet 172.29.0.0/16 \
  --gateway 172.29.0.1 \
  provider-a
```


In Docker:

```
[EXPECTED OUTPUT]:
  provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Bridge=br-provider-a
  provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Bridge=br-provider-b

[ACTUAL OUTPUT]:
provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Bridge=
provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Bridge=
```


In Podman:

```
[EXPECTED OUTPUT]:
  provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Interface=podmanX (e.g. podman1)
  provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Interface=podmanY (e.g. podman0)

[ACTUAL OUTPUT]:
provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Interface=podman2
provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Interface=podman1
```

Because Netavark manages virtual interfaces automatically, the bridge device name is stored in {{.NetworkInterface}} (which creates kernel devices like podman0, podman1, etc.) rather than the Docker-style option map {{index .Options "bridge"}}.

Sections 3 and 4 have been updated to query {{.NetworkInterface}} and dynamically inspect the corresponding Linux host kernel devices.



---


`which` dependency vs. `command -v`: In minimal Ubuntu installs and cloud images, the which binary is often not installed by default or is deprecated. command -v is a POSIX shell builtin that works natively without external dependencies.

False-Positive Kernel Module Check in Step 2: `MODULES_LOADED=$(lsmod | grep -E "^(wireguard|iptable_nat|iptable_filter)")` evaluates to true as long as at least one module is present. If wireguard loads but iptable_nat fails, `[ -n "${MODULES_LOADED}" ]` still passes. Each module should be validated individually.

Download Pollution in `$PWD (Steps 4 & 5): curl -Lo ./kind and curl -LO .../kubectl` download directly to the caller's current working directory. If executed from a directory without write permissions, it fails, and if successful, it leaves temporary download artifacts behind. Downloading into `/tmp/` is cleaner and safer.

Prevent False-Positive Module Checks in Step 2: 
`lsmod | grep -E '^(wireguard|iptable_nat|iptable_filter)'` passes if any single module is present. Checking each module explicitly ensures that a missing iptable_nat or wireguard module is flagged immediately.


---


Idempotent `iptables` Purging: `iptables -D` deletes only a single matching rule. If the script was re-run multiple times during testing, identical rules accumulate down the chain. Using `while ... iptables -D ...; do :; done` drains all duplicates before inserting fresh rules at positions 1 and 2.

Ephemeral Container Cleanup: In Step 1, if any previous verification left a test container running (like `test-isolation-target`), `podman network rm` would fail because the network endpoint is still locked. Adding test containers to the cleanup list guarantees clean network deletion.

Netavark Interface Discovery: Now that `-o "bridge=..."` is omitted, Netavark dynamically provisions host devices (`podman0`, `podman1`, etc.). Querying `{{.NetworkInterface}}` immediately after creation makes the script report the exact kernel interfaces instantiated on your host.



---

**expected and normal Netavark behavior**.



Unlike the older CNI stack or legacy Docker daemon (which create bridge interfaces in the kernel immediately upon `network create`), **Netavark uses lazy instantiation**:

1. **At `podman network create`:**
Netavark writes the network definition to disk (under `/var/lib/containers/storage/networks/netavark/`) and reserves the next available interface name (`podman1` for Provider B, `podman2` for Provider A). **It does not touch the host kernel yet.**


3. **At first container launch (`podman run --network ...`):**
Netavark creates the bridge interface in the host kernel, brings it `UP`, assigns the `.1` gateway IP (`172.28.0.1` or `172.29.0.1`), and creates the `veth` pair.


5. **In Step 6 of this verification script:**
The test launches `test-isolation-target` on `provider-a` and an Alpine ping container on `provider-b`. Netavark creates `podman1` and `podman2` in the kernel at that moment.


---


### Verifying It Live

If you check `ip -br addr show` right after running Step 6 (or after starting Redis in Step 3), the kernel devices will be present:

```bash
ip -br addr show podman1 podman2

```

Output:

```text
podman1          UP             172.28.0.1/16 ...
podman2          UP             172.29.0.1/16 ...

```

---


---




`map[6379/tcp:[]]` confirms zero host ports are mapped.

Because upstream `redis:7-alpine` contains an `EXPOSE 6379` directive in its image metadata, Podman registers the port in `.NetworkSettings.Ports`, but maps it to an empty slice (`[]`):


- No host mapping (our private setup):

`map[6379/tcp:[]]`

(Port 6379 exists inside the container, but zero host interfaces or ports forward to it.)


- If a host port were published (e.g. -p 6379:6379):

`map[6379/tcp:[{HostIp:0.0.0.0 HostPort:6379}]]`

Combined with `podman port saas-redis` returning empty, this verifies that Redis is completely unmapped to the host network stack.


---

These commands spin up an **ephemeral, throwaway client container** inside the private VPC network (`provider-a`) to test Redis connectivity and data persistence without installing Redis tools on the Ubuntu host.

---

### Command Breakdown

Taking the first command as the blueprint:

```bash
sudo podman run --rm --network provider-a docker.io/library/redis:7-alpine redis-cli -h 172.29.0.20 ping

```

| Component | What It Does |
| --- | --- |
| `sudo podman run` | Creates and starts a new container under the root Podman daemon. |
| `--rm` | **Self-destruct on exit.** As soon as the command finishes, Podman destroys the container, its filesystem layer, and its network namespace. Nothing is left behind in `podman ps -a`. |
| `--network provider-a` | Attaches the container's virtual NIC to the `provider-a` bridge (172.29.0.0/16). Podman's Netavark IPAM gives it a temporary IP (e.g., `172.29.0.2`) on the same subnet as Redis (`172.29.0.20`). |
| `docker.io/library/redis:7-alpine` | Reuses the Redis image already downloaded on your host. Because the image is cached, the container starts in milliseconds. |
| `redis-cli -h 172.29.0.20 <cmd>` | Overrides the default entrypoint (`redis-server`) and instead executes the client utility targeting the private IP of `saas-redis`. |

---

### What Each of the Three Commands Does

1. **`... redis-cli -h 172.29.0.20 ping`**
* **Network test:** Opens a TCP handshake to `172.29.0.20:6379`.
* **L7 handshake:** Sends the Redis `PING` command.
* **Verification:** If the server is listening and healthy, it prints **`PONG`** to stdout.


2. **`... redis-cli -h 172.29.0.20 set test:init 'ok'`**
* **Write operation:** Creates a second ephemeral container, connects to `172.29.0.20`, and sets the key `test:init` to the string `'ok'`.
* **Verification:** Confirms Redis is not read-only and memory allocation succeeds (returns **`OK`**).


3. **`... redis-cli -h 172.29.0.20 get test:init`**
* **Read operation & persistence:** Creates a third ephemeral container and requests the value for `test:init`.
* **Verification:** Redis returns **`"ok"`**, proving the data written by container #2 remained in `saas-redis` memory after container #2 was destroyed.



---

### Why Run It This Way?

1. **Zero Host Port Leakage:** Because `saas-redis` was started without `-p 6379:6379`, the host cannot reach Redis via `localhost:6379`. Running a container connected to `--network provider-a` places the client *inside* the private VPC subnet.
2. **Zero Host Tooling Dependencies:** You don't need `redis-tools` or `redis-cli` installed on your Ubuntu host.
3. **Simulates Real Workload Behavior:** It proves that any workload attached to `provider-a` (like the Gateway's `eth1` or the Kind cluster's `eth1`) can resolve ARP, complete a TCP 3-way handshake, and read/write to the database.

---


Kubeconfig Server Endpoint Sanitization: When pulling `/etc/kubernetes/admin.conf` directly from inside the container, kubeadm writes `server: https://provider-a-k8s-control-plane:6443`. The host cannot resolve that container hostname unless it is rewritten to `127.0.0.1:6443`, or unless `kind get kubeconfig --name provider-a-k8s` is used to export it with host port mapping pre-configured.

Pre-Flight Network Guard: Validates that `provider-a` exists and `podman.socket` is active before Kind spins up, preventing container runtime lockups.



