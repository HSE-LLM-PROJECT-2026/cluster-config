#!/bin/bash
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
NAMESPACE="${NAMESPACE:-hse-llm-project}"
SECRET_NAME="${SECRET_NAME:-huggingface-token}"
SECRET_KEY="${SECRET_KEY:-token}"
HF_TOKEN="${HF_TOKEN:-}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-}"
VERIFY_HF_TOKEN="${VERIFY_HF_TOKEN:-true}"

log() {
  echo "[huggingface-token-secret] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[huggingface-token-secret] ERROR: command not found: $1" >&2
    exit 1
  }
}

is_true() {
  case "${1,,}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_token() {
  local token_value="${HF_TOKEN}"

  if [[ -z "$token_value" && -n "$HF_TOKEN_FILE" ]]; then
    [[ -f "$HF_TOKEN_FILE" ]] || {
      echo "[huggingface-token-secret] ERROR: HF_TOKEN_FILE not found: $HF_TOKEN_FILE" >&2
      exit 1
    }
    token_value="$(tr -d '\r\n' < "$HF_TOKEN_FILE")"
  fi

  printf '%s' "$token_value"
}

verify_token() {
  local token_value="$1"
  if ! is_true "$VERIFY_HF_TOKEN"; then
    log "Token verification disabled (VERIFY_HF_TOKEN=false)."
    return 0
  fi

  log "Validating HF token via /api/whoami-v2 ..."
  curl -fsS \
    -H "Authorization: Bearer ${token_value}" \
    https://huggingface.co/api/whoami-v2 >/dev/null
  log "HF token validation passed."
}

log "Starting deploy from scratch"
log "Namespace: $NAMESPACE"
log "Secret: $SECRET_NAME (key: $SECRET_KEY)"
log "Kubeconfig: $KUBECONFIG_PATH"

need_cmd kubectl
need_cmd curl

[[ -f "$KUBECONFIG_PATH" ]] || {
  echo "[huggingface-token-secret] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
  exit 1
}

export KUBECONFIG="$KUBECONFIG_PATH"

TOKEN_VALUE="$(resolve_token)"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if [[ -z "$TOKEN_VALUE" ]]; then
  if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "Token not provided. Existing secret '$SECRET_NAME' in namespace '$NAMESPACE' will be kept."
    exit 0
  fi

  echo "[huggingface-token-secret] ERROR: token is empty and secret '$SECRET_NAME' does not exist." >&2
  echo "[huggingface-token-secret] Provide HF_TOKEN or HF_TOKEN_FILE to create the secret." >&2
  exit 1
fi

verify_token "$TOKEN_VALUE"

TMP_TOKEN_FILE="$(mktemp)"
trap 'rm -f "$TMP_TOKEN_FILE"' EXIT
printf '%s' "$TOKEN_VALUE" > "$TMP_TOKEN_FILE"

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file="${SECRET_KEY}=$TMP_TOKEN_FILE" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Secret applied: $NAMESPACE/$SECRET_NAME"
kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o wide

log "Deploy completed."
