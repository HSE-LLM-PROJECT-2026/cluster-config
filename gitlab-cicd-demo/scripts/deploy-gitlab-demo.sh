#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="$ROOT_DIR/manifests"
NAMESPACE="gitlab-demo"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found"
  exit 1
fi

echo "[1/4] Applying namespace + storage + GitLab manifests"
kubectl apply -f "$MANIFESTS_DIR/00-namespace.yaml"
kubectl apply -f "$MANIFESTS_DIR/01-pv-pvc.yaml"
kubectl apply -f "$MANIFESTS_DIR/02-gitlab-secret.yaml"
kubectl apply -f "$MANIFESTS_DIR/03-gitlab-statefulset.yaml"
kubectl apply -f "$MANIFESTS_DIR/04-gitlab-service.yaml"
kubectl apply -f "$MANIFESTS_DIR/07-gitlab-reference-grant.yaml"
kubectl apply -f "$MANIFESTS_DIR/08-gitlab-external-httproute.yaml"
kubectl apply -f "$MANIFESTS_DIR/09-gitlab-frontend-path-httproute.yaml"

echo "[2/4] Waiting for GitLab pod to be ready (this can take 10-20 minutes on first start)"
kubectl -n "$NAMESPACE" rollout status statefulset/gitlab --timeout=45m

echo "[3/4] Waiting for HTTP health endpoint"
for _ in $(seq 1 120); do
  if kubectl -n "$NAMESPACE" exec statefulset/gitlab -- bash -lc 'curl -fsS http://127.0.0.1/-/health >/dev/null' >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

echo "[4/4] GitLab is deployed"
echo "NodePort URL: http://<node-ip>:30080"
echo "Public URL: https://frontend.hse-llm-project-2026.ru/gitlab"
echo "Root password:"
kubectl -n "$NAMESPACE" get secret gitlab-root-secret -o jsonpath='{.data.password}' | base64 -d; echo

echo
echo "Next steps:"
echo "  ./scripts/bootstrap-runner.sh"
echo "  ./scripts/bootstrap-demo-project.sh"
