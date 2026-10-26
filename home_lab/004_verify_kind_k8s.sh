#!/usr/bin/env bash
# ==============================================================================
# Script: 004_verify_kind_k8s.sh
# Purpose: Comprehensive validation of Kind cluster lifecycle, VPC IP attachment,
#          Kubernetes API state, sample workload pods, NodePort listeners,
#          intra-VPC HTTP curl probe, and cross-bridge isolation enforcement.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"
KUBECONFIG_PATH="/tmp/admin.conf"

echo "${SEPARATOR}"
echo "1. VERIFY KIND CLUSTER & CONTAINER REGISTRATION"
echo "WHY: Confirms the Kind cluster is active and the backing control-plane"
echo "     container is running under Podman."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters"
echo "  sudo podman ps --filter 'name=provider-a-k8s-control-plane' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  provider-a-k8s"
echo "  NAMES                            STATUS       IMAGE"
echo "  provider-a-k8s-control-plane    Up ...       kindest/node:..."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Kind Clusters   : "
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get clusters
sudo podman ps --filter "name=provider-a-k8s-control-plane" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "2. VERIFY MULTI-HOMED VPC INTERFACE & STATIC IP (172.29.0.30)"
echo "WHY: Verifies the Kind container has two virtual NICs: one on the default"
echo "     kind network, and eth1 connected to provider-a holding 172.29.0.30."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman inspect provider-a-k8s-control-plane \\"
echo "    --format '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}: IP={{\$v.IPAddress}} (Gateway={{\$v.Gateway}}){{\"\n\"}}{{end}}'"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  kind: IP=10.89.x.x ..."
echo "  provider-a: IP=172.29.0.30 (Gateway=172.29.0.1)"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman inspect provider-a-k8s-control-plane \
  --format '{{range $k, $v := .NetworkSettings.Networks}}  - {{$k}}: IP={{$v.IPAddress}} (Gateway={{$v.Gateway}}){{"\n"}}{{end}}'
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "3. VERIFY KUBERNETES NODE STATUS & API HEALTH"
echo "WHY: Confirms the control plane is Ready and scheduling workloads properly."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo kubectl --kubeconfig=${KUBECONFIG_PATH} get nodes -o wide"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  NAME                           STATUS   ROLES           VERSION"
echo "  provider-a-k8s-control-plane   Ready    control-plane   v1.x.x"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo kubectl --kubeconfig="${KUBECONFIG_PATH}" get nodes -o wide
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "4. VERIFY WORKLOAD PODS AND NODEPORT SERVICE"
echo "WHY: Confirms the sample-workload pod is Running and the sample-service"
echo "     has bound NodePort 30080 across all node interfaces."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo kubectl --kubeconfig=${KUBECONFIG_PATH} get deployment,pods,svc -o wide"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  deployment.apps/sample-workload   1/1 ready"
echo "  pod/sample-workload-...           Running"
echo "  service/sample-service NodePort   80:30080/TCP"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo kubectl --kubeconfig="${KUBECONFIG_PATH}" get deployment,pods,svc -o wide
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "5. FUNCTIONAL INTRA-VPC HTTP PROBE (TESTING 172.29.0.30:30080)"
echo "WHY: Proves that workloads inside Provider A VPC can query the Kubernetes"
echo "     NodePort service at 172.29.0.30:30080 and receive the expected HTTP payload."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run --rm --network provider-a docker.io/library/curlimages/curl:8.10.1 \\"
echo "    -s http://172.29.0.30:30080"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard"
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  HTTP Response: "
sudo podman run --rm --network provider-a docker.io/library/curlimages/curl:8.10.1 \
  -s http://172.29.0.30:30080 2>/dev/null || echo "FAILED to connect inside VPC"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "6. NEGATIVE ISOLATION CHECK: CROSS-BRIDGE PROBE (PROVIDER B -> K8S)"
echo "WHY: Confirms that without the WireGuard gateway active, nodes on provider-b"
echo "     CANNOT reach 172.29.0.30:30080 directly due to iptables FORWARD drops."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman run --rm --network provider-b docker.io/library/curlimages/curl:8.10.1 \\"
echo "    --connect-timeout 2 -s http://172.29.0.30:30080"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Connection timed out (100% blocked by iptables isolation rule #1)."
echo ""
echo "[ACTUAL OUTPUT]:"
echo -n "  Cross-Bridge Probe Result: "
PROBE_RESULT=$(sudo podman run --rm --network provider-b docker.io/library/curlimages/curl:8.10.1 \
  --connect-timeout 2 -s http://172.29.0.30:30080 2>&1 || true)

if [ -z "${PROBE_RESULT}" ]; then
  echo "PASSED (Connection timed out / dropped as expected - VPC is isolated)."
else
  echo "FAILED (Unexpected response: ${PROBE_RESULT})"
fi
echo "${SEPARATOR}"
