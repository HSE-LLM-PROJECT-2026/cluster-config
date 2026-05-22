#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  echo "Create it from .env.example" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

resolve_path() {
  local path="$1"
  if [[ "${path}" = /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${SCRIPT_DIR}/${path}"
  fi
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: command not found: ${cmd}" >&2
    exit 1
  fi
}

require_var() {
  local name="$1"
  local value="${!name:-}"
  if [[ -z "${value}" ]]; then
    echo "ERROR: required variable is empty: ${name}" >&2
    exit 1
  fi
}

wait_talos_ready() {
  local node_ip="$1"
  local timeout="$2"
  local elapsed=0

  while (( elapsed < timeout )); do
    if talosctl version --insecure --nodes "${node_ip}" >/dev/null 2>&1; then
      return 0
    fi

    if talosctl --talosconfig "${TALOSCONFIG_PATH}" --endpoints "${node_ip}" --nodes "${node_ip}" version >/dev/null 2>&1; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

wait_talos_secure() {
  local endpoint="$1"
  local node="$2"
  local timeout="$3"
  local elapsed=0

  while (( elapsed < timeout )); do
    if talosctl --talosconfig "${TALOSCONFIG_PATH}" --endpoints "${endpoint}" --nodes "${node}" version >/dev/null 2>&1; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

choose_talos_endpoint() {
  local timeout="$1"
  shift

  local candidate
  for candidate in "$@"; do
    [[ -z "${candidate}" ]] && continue
    if wait_talos_secure "${candidate}" "${candidate}" "${timeout}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

wait_kube_api() {
  local timeout="$1"
  local elapsed=0

  while (( elapsed < timeout )); do
    if kubectl --kubeconfig "${KUBECONFIG_PATH}" get --raw='/readyz' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

wait_metrics_api() {
  local timeout="$1"
  local elapsed=0

  while (( elapsed < timeout )); do
    local available_status
    available_status="$(
      kubectl --kubeconfig "${KUBECONFIG_PATH}" get apiservice v1beta1.metrics.k8s.io \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true
    )"
    if [[ "${available_status}" == "True" ]]; then
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

install_metrics_server() {
  local manifest_url="$1"
  local wait_seconds="$2"
  local use_insecure_tls="$3"
  local pin_node_hostname="$4"

  echo "== Install Metrics API (metrics-server) =="
  kubectl --kubeconfig "${KUBECONFIG_PATH}" apply -f "${manifest_url}"

  if [[ "${use_insecure_tls}" == "true" ]]; then
    local current_args
    current_args="$(
      kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system get deployment metrics-server \
        -o jsonpath='{.spec.template.spec.containers[0].args[*]}' 2>/dev/null || true
    )"

    if [[ "${current_args}" != *"--kubelet-insecure-tls"* ]]; then
      kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system patch deployment metrics-server \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    fi
  fi

  if [[ -n "${pin_node_hostname}" ]]; then
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system patch deployment metrics-server \
      --type='merge' \
      -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${pin_node_hostname}\"}}}}}"
  fi

  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system rollout status deployment metrics-server \
    --timeout="${wait_seconds}s"

  if wait_metrics_api "${wait_seconds}"; then
    echo "Metrics API is ready."
  else
    echo "ERROR: metrics.k8s.io API did not become ready in ${wait_seconds}s." >&2
    echo "Check metrics-server logs: kubectl -n kube-system logs deploy/metrics-server --tail=200" >&2
    exit 1
  fi
}

apply_config() {
  local node_ip="$1"
  local cfg_file="$2"

  if [[ ! -f "${cfg_file}" ]]; then
    echo "ERROR: node config not found: ${cfg_file}" >&2
    exit 1
  fi

  talosctl apply-config --insecure --nodes "${node_ip}" --file "${cfg_file}"
}

bootstrap_etcd() {
  local out
  set +e
  out="$(talosctl --talosconfig "${TALOSCONFIG_PATH}" bootstrap 2>&1)"
  local rc=$?
  set -e

  if (( rc == 0 )); then
    return 0
  fi

  if echo "${out}" | grep -Eiq 'already (bootstrapped|initialized)|bootstrap already completed'; then
    return 0
  fi

  echo "${out}" >&2
  return 1
}

main() {
  require_command talosctl
  require_command kubectl

  CP_IP="${CP_IP:-}"
  WORKER_1_IP="${WORKER_1_IP:-}"
  GPU_V100_IP="${GPU_V100_IP:-}"
  WORKER_2_IP="${WORKER_2_IP:-}"
  WORKER_3_IP="${WORKER_3_IP:-}"

  CP_VPN_IP="${CP_VPN_IP:-}"

  CP_HOSTNAME="${CP_HOSTNAME:-cp}"
  WORKER_1_HOSTNAME="${WORKER_1_HOSTNAME:-worker-1}"
  GPU_V100_HOSTNAME="${GPU_V100_HOSTNAME:-gpu-worker-v100}"
  WORKER_2_HOSTNAME="${WORKER_2_HOSTNAME:-worker-2}"
  WORKER_3_HOSTNAME="${WORKER_3_HOSTNAME:-worker-3}"

  APPLY_WORKERS="${APPLY_WORKERS:-true}"
  APPLY_WORKER_3="${APPLY_WORKER_3:-false}"
  WAIT_CP_SECONDS="${WAIT_CP_SECONDS:-90}"
  WAIT_API_TIMEOUT_SECONDS="${WAIT_API_TIMEOUT_SECONDS:-600}"
  INSTALL_METRICS_SERVER="${INSTALL_METRICS_SERVER:-true}"
  METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml}"
  METRICS_SERVER_KUBELET_INSECURE_TLS="${METRICS_SERVER_KUBELET_INSECURE_TLS:-true}"
  METRICS_SERVER_WAIT_SECONDS="${METRICS_SERVER_WAIT_SECONDS:-180}"
  METRICS_SERVER_NODE_HOSTNAME="${METRICS_SERVER_NODE_HOSTNAME:-}"

  TALOSCONFIG_PATH="$(resolve_path "${TALOSCONFIG_PATH:-./talosconfig}")"
  KUBECONFIG_PATH="$(resolve_path "${KUBECONFIG_PATH:-./kubeconfig}")"
  NODE_CONFIGS_DIR="$(resolve_path "${NODE_CONFIGS_DIR:-./node-configs}")"
  TALOS_ENDPOINT="${TALOS_ENDPOINT:-}"

  CP_NODE_CONFIG="$(resolve_path "${CP_NODE_CONFIG:-${NODE_CONFIGS_DIR}/${CP_HOSTNAME}.yaml}")"
  WORKER_1_NODE_CONFIG="$(resolve_path "${WORKER_1_NODE_CONFIG:-${NODE_CONFIGS_DIR}/${WORKER_1_HOSTNAME}.yaml}")"
  GPU_V100_NODE_CONFIG="$(resolve_path "${GPU_V100_NODE_CONFIG:-${NODE_CONFIGS_DIR}/${GPU_V100_HOSTNAME}.yaml}")"
  WORKER_2_NODE_CONFIG="$(resolve_path "${WORKER_2_NODE_CONFIG:-${NODE_CONFIGS_DIR}/${WORKER_2_HOSTNAME}.yaml}")"
  WORKER_3_NODE_CONFIG="$(resolve_path "${WORKER_3_NODE_CONFIG:-${NODE_CONFIGS_DIR}/${WORKER_3_HOSTNAME}.yaml}")"

  require_var CP_IP
  require_var CP_VPN_IP

  if [[ ! -f "${TALOSCONFIG_PATH}" ]]; then
    echo "ERROR: talosconfig not found: ${TALOSCONFIG_PATH}" >&2
    exit 1
  fi

  if [[ ! -f "${CP_NODE_CONFIG}" ]]; then
    echo "ERROR: control-plane node config not found: ${CP_NODE_CONFIG}" >&2
    exit 1
  fi

  if [[ "${APPLY_WORKERS}" == "true" ]]; then
    require_var WORKER_1_IP
    require_var GPU_V100_IP
    require_var WORKER_2_IP

    for cfg in \
      "${WORKER_1_NODE_CONFIG}" \
      "${GPU_V100_NODE_CONFIG}" \
      "${WORKER_2_NODE_CONFIG}"
    do
      [[ -f "${cfg}" ]] || { echo "ERROR: worker node config not found: ${cfg}" >&2; exit 1; }
    done

    if [[ "${APPLY_WORKER_3}" == "true" ]]; then
      require_var WORKER_3_IP
      [[ -f "${WORKER_3_NODE_CONFIG}" ]] || { echo "ERROR: worker-3 node config not found: ${WORKER_3_NODE_CONFIG}" >&2; exit 1; }
    fi
  fi

  echo "== Using static per-node Talos configs =="
  echo "Node configs dir: ${NODE_CONFIGS_DIR}"
  echo "Talosconfig: ${TALOSCONFIG_PATH}"

  echo "== Apply control-plane config (${CP_IP}) =="
  apply_config "${CP_IP}" "${CP_NODE_CONFIG}"

  echo "== Wait control-plane Talos API =="
  if ! wait_talos_ready "${CP_IP}" "${WAIT_API_TIMEOUT_SECONDS}"; then
    echo "ERROR: control-plane Talos API is not reachable: ${CP_IP}" >&2
    exit 1
  fi

  sleep "${WAIT_CP_SECONDS}"

  local_talos_endpoint="${TALOS_ENDPOINT:-}"
  if [[ -z "${local_talos_endpoint}" ]]; then
    if ! local_talos_endpoint="$(choose_talos_endpoint 20 "${CP_VPN_IP}" "${CP_IP}")"; then
      echo "ERROR: could not determine reachable secure Talos endpoint" >&2
      exit 1
    fi
  fi

  export TALOSCONFIG="${TALOSCONFIG_PATH}"
  talosctl --talosconfig "${TALOSCONFIG_PATH}" config endpoint "${local_talos_endpoint}"
  talosctl --talosconfig "${TALOSCONFIG_PATH}" config node "${local_talos_endpoint}"

  echo "== Using Talos endpoint: ${local_talos_endpoint} =="

  echo "== Bootstrap etcd =="
  bootstrap_etcd

  echo "== Fetch kubeconfig =="
  talosctl --talosconfig "${TALOSCONFIG_PATH}" kubeconfig "${KUBECONFIG_PATH}" --force
  export KUBECONFIG="${KUBECONFIG_PATH}"

  echo "== Wait Kubernetes API =="
  if ! wait_kube_api "${WAIT_API_TIMEOUT_SECONDS}"; then
    echo "ERROR: kubernetes api is not ready" >&2
    echo "Check kubeconfig endpoint and control-plane health." >&2
    exit 1
  fi

  if [[ "${APPLY_WORKERS}" == "true" ]]; then
    echo "== Apply worker configs =="
    apply_config "${WORKER_1_IP}" "${WORKER_1_NODE_CONFIG}"
    apply_config "${GPU_V100_IP}" "${GPU_V100_NODE_CONFIG}"
    apply_config "${WORKER_2_IP}" "${WORKER_2_NODE_CONFIG}"

    if [[ "${APPLY_WORKER_3}" == "true" ]]; then
      apply_config "${WORKER_3_IP}" "${WORKER_3_NODE_CONFIG}"
    fi
  fi

  if [[ "${INSTALL_METRICS_SERVER}" == "true" ]]; then
    install_metrics_server \
      "${METRICS_SERVER_MANIFEST_URL}" \
      "${METRICS_SERVER_WAIT_SECONDS}" \
      "${METRICS_SERVER_KUBELET_INSECURE_TLS}" \
      "${METRICS_SERVER_NODE_HOSTNAME}"
  else
    echo "== Skip Metrics API install (INSTALL_METRICS_SERVER=${INSTALL_METRICS_SERVER}) =="
  fi

  echo "== Done =="
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide || true
  kubectl --kubeconfig "${KUBECONFIG_PATH}" top nodes || true
}

main "$@"
