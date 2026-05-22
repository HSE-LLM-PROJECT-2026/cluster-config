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
DISABLE_NODE_AUTORECOVERY="${DISABLE_NODE_AUTORECOVERY:-true}"
NODE_AUTORECOVERY_DIR="${NODE_AUTORECOVERY_DIR:-/home/oleg/Documents/hse-llm-project/cluster-config/node-autorecovery}"

log() {
  echo "[hardening-package] $*"
}

is_true() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$raw" == "1" || "$raw" == "true" || "$raw" == "yes" || "$raw" == "on" ]]
}

[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[hardening-package] ERROR: kubeconfig not found: ${KUBECONFIG_PATH}" >&2
  exit 1
}
export KUBECONFIG="$KUBECONFIG_PATH"

kubectl delete -f "${MANIFESTS_DIR}/10-priority-classes.yaml" --ignore-not-found >/dev/null 2>&1 || true

sed "s/namespace: hse-llm-project/namespace: ${TARGET_NAMESPACE}/g" \
  "${MANIFESTS_DIR}/20-limitrange-hse-llm-project.yaml" | kubectl delete -f - --ignore-not-found >/dev/null 2>&1 || true

sed "s/namespace: hse-llm-project/namespace: ${TARGET_NAMESPACE}/g" \
  "${MANIFESTS_DIR}/30-pdb-platform-services.yaml" | kubectl delete -f - --ignore-not-found >/dev/null 2>&1 || true

if kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  sed "s/namespace: monitoring/namespace: ${MONITORING_NAMESPACE}/g" \
    "${MANIFESTS_DIR}/40-prometheusrule-node-stability.yaml" | kubectl delete -f - --ignore-not-found >/dev/null 2>&1 || true
fi

if is_true "$DISABLE_NODE_AUTORECOVERY"; then
  if [[ -d "$NODE_AUTORECOVERY_DIR" && -x "$NODE_AUTORECOVERY_DIR/uninstall-systemd.sh" ]]; then
    (
      cd "$NODE_AUTORECOVERY_DIR"
      ./uninstall-systemd.sh
    )
  fi
fi

log "Hardening package resources removed."

