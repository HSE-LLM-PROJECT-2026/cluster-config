#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="$ROOT_DIR/manifests"
NAMESPACE="gitlab-demo"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found"
  exit 1
fi

echo "[1/5] Ensuring GitLab is ready"
kubectl -n "$NAMESPACE" rollout status statefulset/gitlab --timeout=45m

echo "[2/5] Reading runner registration token from GitLab"
set +e
REG_TOKEN=$(kubectl -n "$NAMESPACE" exec statefulset/gitlab -- bash -lc "gitlab-rails runner \"puts ApplicationSetting.current.runners_registration_token\"" 2>/dev/null | tail -n1 | tr -d '\r')
set -e

if [[ -z "${REG_TOKEN}" ]]; then
  echo "Primary token command returned empty, trying fallback"
  REG_TOKEN=$(kubectl -n "$NAMESPACE" exec statefulset/gitlab -- bash -lc "gitlab-rails runner \"puts Gitlab::CurrentSettings.current_application_settings.runners_registration_token\"" | tail -n1 | tr -d '\r')
fi

if [[ -z "${REG_TOKEN}" ]]; then
  echo "Failed to fetch runner registration token"
  exit 1
fi

echo "[3/5] Creating/updating runner token secret"
kubectl -n "$NAMESPACE" create secret generic gitlab-runner-registration-token \
  --from-literal=token="$REG_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[4/5] Deploying runner"
kubectl apply -f "$MANIFESTS_DIR/06-gitlab-runner.yaml"
kubectl -n "$NAMESPACE" rollout status deploy/gitlab-runner --timeout=10m

echo "[5/5] Runner logs (tail)"
kubectl -n "$NAMESPACE" logs deploy/gitlab-runner --tail=40 || true

echo "Runner bootstrap completed"
