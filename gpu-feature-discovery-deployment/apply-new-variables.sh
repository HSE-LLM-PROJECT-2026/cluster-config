#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${VALUES_FILE:-$SCRIPT_DIR/values.gpu-feature-discovery.yaml}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-gpu-feature-discovery}"
RELEASE_NAME="${RELEASE_NAME:-gpu-feature-discovery}"
CHART_VERSION="${CHART_VERSION:-0.19.0}"
CHART_NAME="nvdp/gpu-feature-discovery"
PSA_LEVEL="${PSA_LEVEL:-privileged}"

log() {
  echo "[gpu-feature-discovery] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[gpu-feature-discovery] ERROR: command not found: $1" >&2
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
  echo "[gpu-feature-discovery] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

[[ -f "$VALUES_FILE" ]] || {
  echo "[gpu-feature-discovery] ERROR: values file not found: $VALUES_FILE" >&2
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
  echo "[gpu-feature-discovery] ERROR: release '$RELEASE_NAME' not found in namespace '$NAMESPACE'" >&2
  echo "[gpu-feature-discovery] Run ./deploy-from-scratch.sh first" >&2
  exit 1
fi

HELM_VERSION_ARGS=()
if [[ -n "$CHART_VERSION" ]]; then
  HELM_VERSION_ARGS=(--version "$CHART_VERSION")
fi

log "Applying new values via helm upgrade..."
helm upgrade "$RELEASE_NAME" "$CHART_NAME" \
  "${HELM_VERSION_ARGS[@]}" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE"

mapfile -t DAEMONSETS < <(
  kubectl get daemonset -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$RELEASE_NAME" \
    -o name
)

if [[ "${#DAEMONSETS[@]}" -eq 0 ]]; then
  echo "[gpu-feature-discovery] ERROR: no daemonsets found for release '$RELEASE_NAME'" >&2
  exit 1
fi

log "Waiting for daemonsets rollout..."
for ds in "${DAEMONSETS[@]}"; do
  kubectl rollout status "$ds" -n "$NAMESPACE" --timeout=300s
done

log "Update finished. Current resources:"
kubectl get pods,daemonsets -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME"

log "GPU label snapshot:"
kubectl get nodes \
  -L nvidia.com/gpu.count \
  -L nvidia.com/gpu.product \
  -L nvidia.com/gpu.compute.major \
  -L nvidia.com/gpu.compute.minor

log "Update completed."
