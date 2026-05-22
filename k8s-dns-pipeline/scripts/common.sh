#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
DNS_SERVER="${DNS_SERVER:-10.42.0.10}"
DNS_DOMAIN="${DNS_DOMAIN:-hse-llm-project-2026.ru}"

log() {
  echo "[dns-pipeline] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[dns-pipeline] ERROR: command not found: $1" >&2
    exit 1
  }
}

require_kubeconfig() {
  [[ -f "$KUBECONFIG_PATH" ]] || {
    echo "[dns-pipeline] ERROR: kubeconfig not found: $KUBECONFIG_PATH" >&2
    exit 1
  }
  export KUBECONFIG="$KUBECONFIG_PATH"
}
