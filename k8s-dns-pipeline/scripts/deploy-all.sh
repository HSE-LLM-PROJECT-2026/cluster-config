#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DNS_SERVER="${DNS_SERVER:-10.42.0.10}"
INSTALL_CILIUM="${INSTALL_CILIUM:-true}"
CILIUM_RELEASE="${CILIUM_RELEASE:-cilium}"
CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.0}"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

ok() {
  echo -e "${GREEN}[OK]${NC} $*"
}

fail() {
  echo -e "${RED}[FAIL]${NC} $*" >&2
}

step() {
  echo -e "${YELLOW}== $* ==${NC}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "command not found: $1"
    exit 1
  }
}

apply_dir() {
  local dir="$1"
  step "Apply ${dir}"
  kubectl apply -f "${ROOT_DIR}/${dir}"
  ok "Applied ${dir}"
}

wait_rollout() {
  local namespace="$1"
  local deployment_name="$2"
  step "Rollout ${namespace}/${deployment_name}"
  kubectl -n "${namespace}" rollout status "deployment/${deployment_name}" --timeout=120s
  ok "Rollout ready: ${namespace}/${deployment_name}"
}

wait_for_gateway_ip() {
  local timeout_seconds=120
  local elapsed=0
  local gateway_ip=""

  step "Wait for Gateway address"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    gateway_ip="$(kubectl -n kube-system get gateway web-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    if [[ -n "${gateway_ip}" ]]; then
      ok "Gateway address: ${gateway_ip}"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Gateway address is not assigned after ${timeout_seconds}s"
  return 1
}

wait_for_coredns_lb_ip() {
  local timeout_seconds=120
  local elapsed=0
  local lb_ip=""

  step "Wait for external CoreDNS LoadBalancer IP"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    lb_ip="$(kubectl -n kube-system get svc external-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${lb_ip}" ]]; then
      ok "external-coredns LoadBalancer IP: ${lb_ip}"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "external-coredns did not receive LoadBalancer IP after ${timeout_seconds}s"
  return 1
}

wait_for_gatewayclass() {
  local timeout_seconds=180
  local elapsed=0

  step "Wait for GatewayClass cilium"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    if kubectl get gatewayclass cilium >/dev/null 2>&1; then
      ok "GatewayClass cilium is present"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "GatewayClass cilium was not created after ${timeout_seconds}s"
  return 1
}

wait_for_cilium_status_cli() {
  if command -v cilium >/dev/null 2>&1; then
    step "Wait for Cilium via cilium status --wait"
    cilium status --wait
    ok "Cilium status is OK"
  else
    step "cilium CLI not found; skip cilium status check"
  fi
}

existing_cilium_is_ready() {
  if ! kubectl -n "${CILIUM_NAMESPACE}" get daemonset cilium >/dev/null 2>&1; then
    return 1
  fi

  step "Detected existing Cilium DaemonSet in ${CILIUM_NAMESPACE}"
  if ! kubectl -n "${CILIUM_NAMESPACE}" rollout status daemonset/cilium --timeout=300s >/dev/null 2>&1; then
    fail "Existing Cilium DaemonSet is not ready"
    return 1
  fi
  ok "Existing Cilium DaemonSet is ready"

  wait_for_cilium_status_cli

  if kubectl get gatewayclass cilium >/dev/null 2>&1; then
    ok "Existing GatewayClass cilium is present"
    return 0
  fi

  step "GatewayClass cilium is missing; will (re)apply Cilium Helm release"
  return 1
}

ensure_cilium() {
  if [[ "${INSTALL_CILIUM}" != "true" ]]; then
    step "Skip Cilium install (INSTALL_CILIUM=${INSTALL_CILIUM})"
    return 0
  fi

  if existing_cilium_is_ready; then
    step "Using existing manual Cilium installation"
    return 0
  fi

  step "Ensure Cilium is installed"
  need_cmd helm

  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  local helm_args=(
    upgrade
    --install
    "${CILIUM_RELEASE}"
    cilium/cilium
    --namespace
    "${CILIUM_NAMESPACE}"
    --create-namespace
    --set
    ipam.mode=kubernetes
    --set
    kubeProxyReplacement=true
    --set
    "securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
    --set
    "securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
    --set
    cgroup.autoMount.enabled=false
    --set
    cgroup.hostRoot=/sys/fs/cgroup
    --set
    k8sServiceHost=localhost
    --set
    k8sServicePort=7445
    --set
    gatewayAPI.enabled=true
    --set
    gatewayAPI.enableAlpn=true
    --set
    gatewayAPI.enableAppProtocol=true
  )

  if [[ -n "${CILIUM_VERSION}" ]]; then
    helm_args+=(--version "${CILIUM_VERSION}")
  fi

  helm "${helm_args[@]}"
  ok "Cilium release applied: ${CILIUM_RELEASE} (${CILIUM_NAMESPACE})"

  step "Wait for cilium DaemonSet"
  kubectl -n "${CILIUM_NAMESPACE}" rollout status daemonset/cilium --timeout=300s
  ok "DaemonSet cilium is ready"

  local operator_deployment=""
  operator_deployment="$(kubectl -n "${CILIUM_NAMESPACE}" get deploy -l k8s-app=cilium-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${operator_deployment}" ]]; then
    operator_deployment="$(kubectl -n "${CILIUM_NAMESPACE}" get deploy -l app.kubernetes.io/name=cilium-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  fi
  if [[ -n "${operator_deployment}" ]]; then
    step "Wait for ${operator_deployment} Deployment"
    kubectl -n "${CILIUM_NAMESPACE}" rollout status "deployment/${operator_deployment}" --timeout=300s
    ok "Deployment ${operator_deployment} is ready"
  fi

  wait_for_cilium_status_cli
  wait_for_gatewayclass
}

main() {
  need_cmd kubectl
  ensure_cilium

  apply_dir "00-namespace"
  kubectl get namespace kube-system >/dev/null
  ok "kube-system namespace is reachable"

  apply_dir "01-etcd"
  wait_rollout "kube-system" "dns-etcd"

  apply_dir "02-coredns-external"
  wait_rollout "kube-system" "external-coredns"
  wait_for_coredns_lb_ip

  apply_dir "03-external-dns"
  wait_rollout "kube-system" "external-dns"

  apply_dir "04-gateway"
  wait_for_gateway_ip

  apply_dir "05-metallb-patch"
  kubectl -n metallb-system get l2advertisement home-pool-advertisement >/dev/null
  ok "MetalLB L2Advertisement is present"

  local coredns_ip
  coredns_ip="$(kubectl -n kube-system get svc external-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  local etcd_ip
  etcd_ip="$(kubectl -n kube-system get svc dns-etcd -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"

  step "Done"
  echo "external-coredns LB IP: ${coredns_ip:-<pending>}"
  echo "dns-etcd ClusterIP: ${etcd_ip:-<pending>}"
  echo "Run DNS test:"
  echo "  dig @${coredns_ip:-${DNS_SERVER}} test.hse-llm-project-2026.ru"
}

main "$@"
