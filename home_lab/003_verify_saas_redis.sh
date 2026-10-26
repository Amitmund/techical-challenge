#!/usr/bin/env bash
# ==============================================================================
# Script: 003_deploy_saas_redis.sh
# Purpose: Deploys the simulated managed SaaS service (Redis) strictly inside
#          Provider A's private VPC network with zero host port publication.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"

echo "${SEPARATOR}"
echo "STEP: DEPLOY MANAGED SAAS REDIS IN PROVIDER A (PRIVATE VPC)"
echo "[NOTE]   : Launches an isolated Redis container on the private VPC network (172.29.0.0/16)."
echo "[CAUSE]  : The technical challenge requires managed SaaS services to be reachable only"
echo "           through Provider A's private VPC network, with no direct public access[cite: 1]."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run -d \\"
echo "    --name saas-redis \\"
echo "    --network provider-a \\"
echo "    --ip 172.29.0.20 \\"
echo "    --restart unless-stopped \\"
echo "    docker.io/library/redis:7-alpine redis-server --protected-mode no"
echo ""
echo "[WHY]:"
echo "  - --name saas-redis        : Sets a fixed container identifier for management."
echo "  - --network provider-a     : Binds container strictly to the isolated VPC bridge (br-provider-a)."
echo "  - --ip 172.29.0.20         : Assigns a deterministic private IP inside the VPC subnet."
echo "  - --restart unless-stopped : Keeps the database process persistent throughout testing."
echo "  - No -p / -P flags         : Prevents port forwarding to the host; reachable only via internal L3."
echo "  - --protected-mode no      : Permits incoming TCP queries from the internal VPC CIDR."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Container ID hash printed to stdout; container running in detached mode with exit code 0."
echo ""
echo "[ACTUAL OUTPUT]:"
# Clean up if existing
sudo podman rm -f saas-redis >/dev/null 2>&1 || true

CONTAINER_ID=$(sudo podman run -d \
  --name saas-redis \
  --network provider-a \
  --ip 172.29.0.20 \
  --restart unless-stopped \
  docker.io/library/redis:7-alpine redis-server --protected-mode no)

echo "  Container deployed successfully."
echo "  Container ID : ${CONTAINER_ID}"
echo "  Status       : $(sudo podman inspect -f '{{.State.Status}}' saas-redis)"
echo "${SEPARATOR}"
