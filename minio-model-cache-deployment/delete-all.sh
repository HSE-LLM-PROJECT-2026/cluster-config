#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-hse-llm-project}"

MINIO_NAME="${MINIO_NAME:-minio-model-cache}"
MINIO_SERVICE_NAME="${MINIO_SERVICE_NAME:-minio-model-cache}"
MINIO_SECRET_NAME="${MINIO_SECRET_NAME:-minio-model-cache-credentials}"
MINIO_PV_NAME="${MINIO_PV_NAME:-minio-model-cache}"
MINIO_CONSOLE_ROUTE_NAME="${MINIO_CONSOLE_ROUTE_NAME:-minio-console-route}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[minio-model-cache] ERROR: command not found: $1" >&2
    exit 1
  }
}

need_cmd kubectl
[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[minio-model-cache] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

export KUBECONFIG="$KUBECONFIG_PATH"

kubectl -n "$NAMESPACE" delete cronjob "${MINIO_NAME}-sync" --ignore-not-found
kubectl -n "$NAMESPACE" delete job "${MINIO_NAME}-sync-once" --ignore-not-found
kubectl -n "$NAMESPACE" delete job "${MINIO_NAME}-bucket-init" --ignore-not-found
kubectl -n "$NAMESPACE" delete httproute "${MINIO_CONSOLE_ROUTE_NAME}" --ignore-not-found
kubectl -n "$NAMESPACE" delete service "$MINIO_SERVICE_NAME" --ignore-not-found
kubectl -n "$NAMESPACE" delete deployment "$MINIO_NAME" --ignore-not-found
kubectl -n "$NAMESPACE" delete pvc "${MINIO_NAME}-data" --ignore-not-found
kubectl -n "$NAMESPACE" delete secret "$MINIO_SECRET_NAME" --ignore-not-found
kubectl delete pv "$MINIO_PV_NAME" --ignore-not-found

echo "[minio-model-cache] Deleted MinIO model cache resources from namespace $NAMESPACE."
