#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-hse-llm-project}"
SECRET_NAME="${SECRET_NAME:-huggingface-token}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-false}"

log() {
  echo "[huggingface-token-secret] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[huggingface-token-secret] ERROR: command not found: $1" >&2
    exit 1
  }
}

log "Starting deletion"
log "Namespace: $NAMESPACE"
log "Secret: $SECRET_NAME"
log "Delete namespace: $DELETE_NAMESPACE"
log "Kubeconfig: $KUBECONFIG_PATH"

need_cmd kubectl

[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[huggingface-token-secret] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

export KUBECONFIG="$KUBECONFIG_PATH"

kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found=true

if [[ "${DELETE_NAMESPACE,,}" == "true" ]]; then
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
fi

log "Delete completed."
