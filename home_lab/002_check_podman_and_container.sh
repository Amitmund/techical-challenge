# Verify Linux Host Bridge Interfaces
# ip -br addr show
ip -br addr show br-provider-a br-provider-b

# Verify Podman Networks - Confirm that provider-a and provider-b are registered in Podman
sudo podman network ls

# Expected output

# NETWORK ID    NAME          DRIVER
# ...           provider-a    bridge
# ...           provider-b    bridge


# Inspect the exact subnets, gateways, and bridge names in Podman's state:
sudo podman network inspect provider-a provider-b \
  --format '{{.Name}}: Subnet={{(index .Subnets 0).Subnet}}, Gateway={{(index .Subnets 0).Gateway}}, Bridge={{index .Options "bridge"}}'

# Expected output
# provider-a: Subnet=172.29.0.0/16, Gateway=172.29.0.1, Bridge=br-provider-a
# provider-b: Subnet=172.28.0.0/16, Gateway=172.28.0.1, Bridge=br-provider-b

# Verify iptables FORWARD Chain Rules
sudo iptables -nvL FORWARD --line-numbers
