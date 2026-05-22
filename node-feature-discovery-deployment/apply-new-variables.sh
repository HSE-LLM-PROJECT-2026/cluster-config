#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${VALUES_FILE:-$SCRIPT_DIR/values.node-feature-discovery.yaml}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-node-feature-discovery}"
RELEASE_NAME="${RELEASE_NAME:-node-feature-discovery}"
CHART_VERSION="${CHART_VERSION:-0.18.3}"
CHART_NAME="node-feature-discovery/node-feature-discovery"
PSA_LEVEL="${PSA_LEVEL:-privileged}"
MASTER_DEPLOYMENT="${MASTER_DEPLOYMENT:-${RELEASE_NAME}-master}"
GC_DEPLOYMENT="${GC_DEPLOYMENT:-${RELEASE_NAME}-gc}"
WORKER_DAEMONSET="${WORKER_DAEMONSET:-${RELEASE_NAME}-worker}"

log() {
  echo "[node-feature-discovery] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[node-feature-discovery] ERROR: command not found: $1" >&2
    exit 1
  }
}

log "Starting values update"
log "Namespace: $NAMESPACE | Release: $RELEASE_NAME"
log "Chart: $CHART_NAME:$CHART_VERSION"
log "Values file: $VALUES_FILE"
log "Kubeconfig: $KUBECONFIG_PATH"
log "PodSecurity level for namespace: $PSA_LEVEL"

log "Checking required commands..."
need_cmd helm
need_cmd kubectl
log "Commands OK"

[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[node-feature-discovery] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

[[ -f "$VALUES_FILE" ]] || {
  echo "[node-feature-discovery] ERROR: values file not found: $VALUES_FILE" >&2
  exit 1
}

export KUBECONFIG="$KUBECONFIG_PATH"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" \
  "pod-security.kubernetes.io/enforce=$PSA_LEVEL" \
  "pod-security.kubernetes.io/audit=$PSA_LEVEL" \
  "pod-security.kubernetes.io/warn=$PSA_LEVEL" \
  --overwrite >/dev/null

if ! helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[node-feature-discovery] ERROR: release '$RELEASE_NAME' not found in namespace '$NAMESPACE'" >&2
  echo "[node-feature-discovery] Run ./deploy-from-scratch.sh first" >&2
  exit 1
fi

log "Applying new values via helm upgrade..."
helm upgrade "$RELEASE_NAME" "$CHART_NAME" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE"

log "Waiting for NFD control-plane components..."
kubectl rollout status "deployment/$MASTER_DEPLOYMENT" -n "$NAMESPACE" --timeout=300s
kubectl rollout status "deployment/$GC_DEPLOYMENT" -n "$NAMESPACE" --timeout=300s

if kubectl get daemonset "$WORKER_DAEMONSET" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl rollout restart "daemonset/$WORKER_DAEMONSET" -n "$NAMESPACE" >/dev/null || true
  kubectl rollout status "daemonset/$WORKER_DAEMONSET" -n "$NAMESPACE" --timeout=300s
fi

log "Update finished. Current NFD resources:"
kubectl get pods,daemonsets,deployments -n "$NAMESPACE"

log "CPU feature labels snapshot (AVX2/F16C):"
kubectl get nodes \
  -L feature.node.kubernetes.io/cpu-cpuid.AVX2 \
  -L feature.node.kubernetes.io/cpu-cpuid.F16C \
  -L feature.node.kubernetes.io/cpu-cpuid.avx2 \
  -L feature.node.kubernetes.io/cpu-cpuid.f16c

log "Update completed."
