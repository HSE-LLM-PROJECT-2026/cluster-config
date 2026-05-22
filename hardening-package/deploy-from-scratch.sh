#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$SCRIPT_DIR/manifests}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-hse-llm-project}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
PSA_ENFORCE="${PSA_ENFORCE:-baseline}"
PSA_AUDIT="${PSA_AUDIT:-restricted}"
PSA_WARN="${PSA_WARN:-restricted}"

APPLY_PRIORITY_CLASSES="${APPLY_PRIORITY_CLASSES:-true}"
APPLY_LIMIT_RANGE="${APPLY_LIMIT_RANGE:-true}"
APPLY_PDB="${APPLY_PDB:-true}"
APPLY_ALERTS="${APPLY_ALERTS:-true}"
ENABLE_NODE_AUTORECOVERY="${ENABLE_NODE_AUTORECOVERY:-true}"
NODE_AUTORECOVERY_DIR="${NODE_AUTORECOVERY_DIR:-/home/oleg/Documents/hse-llm-project/cluster-config/node-autorecovery}"

log() {
  echo "[hardening-package] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[hardening-package] ERROR: command not found: $1" >&2
    exit 1
  }
}

is_true() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$raw" == "1" || "$raw" == "true" || "$raw" == "yes" || "$raw" == "on" ]]
}

need_cmd kubectl
[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[hardening-package] ERROR: kubeconfig not found: ${KUBECONFIG_PATH}" >&2
  exit 1
}
export KUBECONFIG="$KUBECONFIG_PATH"

kubectl create namespace "$TARGET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$TARGET_NAMESPACE" \
  "pod-security.kubernetes.io/enforce=${PSA_ENFORCE}" \
  "pod-security.kubernetes.io/audit=${PSA_AUDIT}" \
  "pod-security.kubernetes.io/warn=${PSA_WARN}" \
  --overwrite >/dev/null
log "Namespace ${TARGET_NAMESPACE} labeled with PSA (enforce=${PSA_ENFORCE}, audit=${PSA_AUDIT}, warn=${PSA_WARN})."

if is_true "$APPLY_PRIORITY_CLASSES"; then
  kubectl apply -f "${MANIFESTS_DIR}/10-priority-classes.yaml"
fi

if is_true "$APPLY_LIMIT_RANGE"; then
  # Materialize target namespace into manifest on the fly.
  sed "s/namespace: hse-llm-project/namespace: ${TARGET_NAMESPACE}/g" \
    "${MANIFESTS_DIR}/20-limitrange-hse-llm-project.yaml" | kubectl apply -f -
fi

if is_true "$APPLY_PDB"; then
  sed "s/namespace: hse-llm-project/namespace: ${TARGET_NAMESPACE}/g" \
    "${MANIFESTS_DIR}/30-pdb-platform-services.yaml" | kubectl apply -f -
fi

if is_true "$APPLY_ALERTS"; then
  if kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
    sed "s/namespace: monitoring/namespace: ${MONITORING_NAMESPACE}/g" \
      "${MANIFESTS_DIR}/40-prometheusrule-node-stability.yaml" | kubectl apply -f -
  else
    log "PrometheusRule CRD not found; skipping alert rules."
  fi
fi

if is_true "$ENABLE_NODE_AUTORECOVERY"; then
  if [[ -d "$NODE_AUTORECOVERY_DIR" && -x "$NODE_AUTORECOVERY_DIR/install-systemd.sh" ]]; then
    (
      cd "$NODE_AUTORECOVERY_DIR"
      ./install-systemd.sh
    )
  else
    log "Node auto-recovery package not found at ${NODE_AUTORECOVERY_DIR}; skipping."
  fi
fi

log "Applied hardening package successfully."
kubectl -n "$TARGET_NAMESPACE" get limitrange,pdb || true
kubectl get priorityclass | rg 'platform-|llm-inference' || true

