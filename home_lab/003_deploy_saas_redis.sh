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
echo "[CAUSE]  : SRE challenge specifies managed SaaS services must be reachable strictly"
echo "           through Provider A's private VPC network, with zero direct public access."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman rm -f saas-redis 2>/dev/null || true"
echo "  sudo podman run -d \\"
echo "    --name saas-redis \\"
echo "    --network provider-a \\"
echo "    --ip 172.29.0.20 \\"
echo "    --restart unless-stopped \\"
echo "    docker.io/library/redis:7-alpine redis-server --protected-mode no"
echo ""
echo "[WHY]:"
echo "  - rm -f saas-redis         : Ensures idempotent re-runs without container name collision."
echo "  - --name saas-redis        : Sets a fixed container identifier for runtime tracking."
echo "  - --network provider-a     : Binds container strictly to the isolated VPC bridge (Netavark)."
echo "  - --ip 172.29.0.20         : Assigns a deterministic private IP inside the VPC subnet."
echo "  - --restart unless-stopped : Keeps the database process persistent throughout testing."
echo "  - No -p / -P flags         : Prevents port forwarding to the host; reachable only via internal L3."
echo "  - --protected-mode no      : Permits incoming TCP queries from internal VPC CIDR workloads."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Container deployed successfully."
echo "  Container ID : <64-char hex hash>"
echo "  Status       : running"
echo "  Assigned IP  : 172.29.0.20"
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
echo "  Status       : $(sudo podman inspect -f '{{.State.Status}}' saas-redis 2>/dev/null || echo 'unknown')"
echo "  Assigned IP  : $(sudo podman inspect saas-redis --format '{{.NetworkSettings.Networks.provider-a.IPAddress}}' 2>/dev/null || echo 'unknown')"
echo "${SEPARATOR}"
