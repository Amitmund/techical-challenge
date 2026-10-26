#!/usr/bin/env bash
# ==============================================================================
# Script: 004_deploy_kind_k8s.sh
# Purpose: Deploys a single-zone Kind Kubernetes cluster via Podman, attaches it
#          to Provider A's private VPC (172.29.0.30), and provisions an HTTP echo
#          sample workload exposed on NodePort 30080.
# ==============================================================================

set -u

SEPARATOR="=============================================================================="
SUB_SEPARATOR="------------------------------------------------------------------------------"
KUBECONFIG_PATH="/tmp/admin.conf"

echo "${SEPARATOR}"
echo "STEP 1: GENERATE KIND CLUSTER CONFIGURATION"
echo "[NOTE]   : Generates kind-config.yaml with explicit control-plane port mappings."
echo "[CAUSE]  : The SRE challenge models Provider A's Kubernetes cluster with internal"
echo "           Ingress / NodePort services accessible only within the VPC."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  mkdir -p ~/wireguard-mock/k8s"
echo "  cat <<EOF > ~/wireguard-mock/k8s/kind-config.yaml"
echo "  ..."
echo ""
echo "[WHY]:"
echo "  - apiServerAddress: 127.0.0.1  : Binds the API server loopback interface safely."
echo "  - containerPort: 30080         : Maps NodePort 30080 for HTTP echo routing."
echo "  - hostPort: 30080              : Binds the port mapping on the node container."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  kind-config.yaml written successfully to disk."
echo ""
echo "[ACTUAL OUTPUT]:"
mkdir -p "${HOME}/wireguard-mock/k8s"
cat <<EOF > "${HOME}/wireguard-mock/k8s/kind-config.yaml"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    listenAddress: "0.0.0.0"
    protocol: TCP
EOF
echo "  Configuration written to: ${HOME}/wireguard-mock/k8s/kind-config.yaml"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 2: PROVISION KIND CLUSTER USING PODMAN PROVIDER"
echo "[NOTE]   : Instantiates the single-node control-plane container via Podman."
echo "[CAUSE]  : Simulates Provider A's Kubernetes compute layer using root Podman"
echo "           socket emulation without needing multi-node hardware VMs."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster \\"
echo "    --name provider-a-k8s \\"
echo "    --config ~/wireguard-mock/k8s/kind-config.yaml"
echo ""
echo "[WHY]:"
echo "  - KIND_EXPERIMENTAL_PROVIDER=podman : Instructs Kind to talk to /run/podman/podman.sock."
echo "  - --name provider-a-k8s             : Identifies the cluster and control-plane container."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Cluster nodes initialized; kubeconfig context set; Kind outputs success."
echo ""
echo "[ACTUAL OUTPUT]:"
# Clean up if partially existing
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name provider-a-k8s >/dev/null 2>&1 || true

sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster \
  --name provider-a-k8s \
  --config "${HOME}/wireguard-mock/k8s/kind-config.yaml"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 3: EXTRACT & EXPORT KUBECONFIG"
echo "[NOTE]   : Extracts the admin kubeconfig from the Kind control-plane container."
echo "[CAUSE]  : Host kubectl requires authenticated client credentials to manage"
echo "           workloads on the local cluster."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman exec provider-a-k8s-control-plane cat /etc/kubernetes/admin.conf > ${KUBECONFIG_PATH}"
echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
echo ""
echo "[WHY]:"
echo "  - Avoids permission conflicts and gives host kubectl direct cluster admin access."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Kubeconfig saved to ${KUBECONFIG_PATH}; cluster certificates readable."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman exec provider-a-k8s-control-plane cat /etc/kubernetes/admin.conf > "${KUBECONFIG_PATH}"
sudo chmod 600 "${KUBECONFIG_PATH}"
echo "  Kubeconfig extracted to: ${KUBECONFIG_PATH}"
sudo kubectl --kubeconfig="${KUBECONFIG_PATH}" cluster-info | head -n 2
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 4: ATTACH KIND CONTROL-PLANE TO PROVIDER A PRIVATE VPC"
echo "[NOTE]   : Hot-plugs a second network interface into the Kind container on 'provider-a'."
echo "[CAUSE]  : By default, Kind attaches only to its own bridge (kind). To simulate being"
echo "           inside Provider A's private VPC, it must bind to 172.29.0.30."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo podman network connect --ip 172.29.0.30 provider-a provider-a-k8s-control-plane"
echo ""
echo "[WHY]:"
echo "  - --ip 172.29.0.30     : Fixed private VPC IP representing internal cluster ingress."
echo "  - provider-a           : Private VPC network shared with Redis and Gateway eth1."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  Network interface successfully attached with exit code 0."
echo ""
echo "[ACTUAL OUTPUT]:"
sudo podman network connect --ip 172.29.0.30 provider-a provider-a-k8s-control-plane
echo "  Container attached to provider-a VPC network."
echo "  Assigned IP: $(sudo podman inspect provider-a-k8s-control-plane --format '{{.NetworkSettings.Networks.provider-a.IPAddress}}')"
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 5: DEPLOY SAMPLE WORKLOAD & EXPOSE NODEPORT SERVICE"
echo "[NOTE]   : Deploys HashiCorp HTTP Echo workload and exposes it on NodePort 30080."
echo "[CAUSE]  : Provides a verifiable HTTP service inside Provider A VPC to confirm that"
echo "           bare-metal nodes can reach internal Kubernetes services via WireGuard."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  cat <<EOF | sudo kubectl --kubeconfig=${KUBECONFIG_PATH} apply -f -"
echo "  Deployment: sample-workload (http-echo:0.2.3 on port 5678)"
echo "  Service   : sample-service  (NodePort: 30080)"
echo "  EOF"
echo ""
echo "[WHY]:"
echo "  - Deployment : Runs a deterministic HTTP listener returning an explicit success string."
echo "  - NodePort   : Binds port 30080 on all node interfaces, including 172.29.0.30."
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  deployment.apps/sample-workload created"
echo "  service/sample-service created"
echo ""
echo "[ACTUAL OUTPUT]:"
cat <<EOF | sudo kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-workload
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sample-workload
  template:
    metadata:
      labels:
        app: sample-workload
    spec:
      containers:
      - name: web
        image: docker.io/hashicorp/http-echo:0.2.3
        args: ["-text=HTTP 200 OK: reached core k8s workload from bare-metal via WireGuard"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: sample-service
  namespace: default
spec:
  type: NodePort
  selector:
    app: sample-workload
  ports:
  - port: 80
    targetPort: 5678
    nodePort: 30080
EOF
echo "${SEPARATOR}"
echo ""


echo "${SEPARATOR}"
echo "STEP 6: WAIT FOR WORKLOAD ROLLOUT READINESS"
echo "[NOTE]   : Blocks until the sample workload pod is in running and ready state."
echo "[CAUSE]  : Container image pull and pod initialization take several seconds."
echo "${SUB_SEPARATOR}"
echo "[COMMAND EXECUTED]:"
echo "  sudo kubectl --kubeconfig=${KUBECONFIG_PATH} rollout status deployment/sample-workload --timeout=90s"
echo ""
echo "[EXPECTED OUTPUT]:"
echo "  deployment \"sample-workload\" successfully rolled out"
echo ""
echo "[ACTUAL OUTPUT]:"
sudo kubectl --kubeconfig="${KUBECONFIG_PATH}" rollout status deployment/sample-workload --timeout=90s
echo "${SEPARATOR}"
