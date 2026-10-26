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


Because Netavark manages virtual interfaces automatically, the bridge device name is stored in {{.NetworkInterface}} (which creates kernel devices like podman0, podman1, etc.) rather than the Docker-style option map {{index .Options "bridge"}}.

Sections 3 and 4 have been updated to query {{.NetworkInterface}} and dynamically inspect the corresponding Linux host kernel devices.


---


