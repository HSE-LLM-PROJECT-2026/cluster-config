#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$SCRIPT_DIR/../../kubeconfig}"
NAMESPACE="${NAMESPACE:-hse-llm-project}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-deployment-service}"
LOCAL_PORT="${LOCAL_PORT:-18000}"
REMOTE_PORT="${REMOTE_PORT:-8000}"
API_BASE_URL="http://127.0.0.1:${LOCAL_PORT}"
API_BEARER_TOKEN="${API_BEARER_TOKEN:-}"

log() {
  echo "[deployment-service-api] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[deployment-service-api] ERROR: command not found: $1" >&2
    exit 1
  }
}

validate_env() {
  require_cmd kubectl
  require_cmd curl

  [[ -f "$KUBECONFIG_PATH" ]] || {
    echo "[deployment-service-api] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
    exit 1
  }
}

kctl() {
  KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

pretty_json() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

normalized_api_bearer_token() {
  local token
  token="$(printf '%s' "$API_BEARER_TOKEN" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ -z "$token" ]]; then
    return 1
  fi
  if [[ "$token" =~ ^[Bb]earer[[:space:]]+ ]]; then
    printf '%s' "$token"
    return 0
  fi
  printf 'Bearer %s' "$token"
}

curl_api() {
  local path="$1"
  shift || true

  local -a args=(-sS)
  local token=""
  token="$(normalized_api_bearer_token || true)"
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: $token")
  fi
  if [[ $# -gt 0 ]]; then
    args+=("$@")
  fi

  curl "${args[@]}" "${API_BASE_URL}${path}"
}

start_temporary_port_forward() {
  PF_LOG_FILE="$(mktemp)"
  KUBECONFIG="$KUBECONFIG_PATH" kubectl -n "$NAMESPACE" \
    port-forward "deployment/${DEPLOYMENT_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}" \
    >"$PF_LOG_FILE" 2>&1 &
  PF_PID=$!

  cleanup_port_forward() {
    if [[ -n "${PF_PID:-}" ]]; then
      kill "$PF_PID" >/dev/null 2>&1 || true
      wait "$PF_PID" >/dev/null 2>&1 || true
    fi
    rm -f "${PF_LOG_FILE:-}"
  }

  trap cleanup_port_forward EXIT INT TERM

  local i
  for i in $(seq 1 40); do
    if ! kill -0 "$PF_PID" >/dev/null 2>&1; then
      echo "[deployment-service-api] ERROR: port-forward exited unexpectedly." >&2
      cat "$PF_LOG_FILE" >&2 || true
      exit 1
    fi

    if curl -sS --max-time 1 "${API_BASE_URL}/health" >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
  done

  echo "[deployment-service-api] ERROR: timeout waiting for deployment-service via port-forward." >&2
  cat "$PF_LOG_FILE" >&2 || true
  exit 1
}
