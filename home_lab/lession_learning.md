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
2. **At first container launch (`podman run --network ...`):**
Netavark creates the bridge interface in the host kernel, brings it `UP`, assigns the `.1` gateway IP (`172.28.0.1` or `172.29.0.1`), and creates the `veth` pair.
3. **In Step 6 of this verification script:**
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



