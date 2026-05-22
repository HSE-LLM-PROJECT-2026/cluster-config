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
  kubectl -n "${namespace}" rollout status "deployment/${deployment_name}" --timeout=180s
  ok "Rollout ready: ${namespace}/${deployment_name}"
}

wait_for_coredns_lb_ip() {
  local timeout_seconds=180
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

main() {
  need_cmd kubectl

  apply_dir "00-namespace"
  apply_dir "01-etcd"
  wait_rollout "kube-system" "dns-etcd"

  # Ensure explicit binding of MetalLB L2Advertisement to home-pool.
  apply_dir "05-metallb-patch"

  apply_dir "02-coredns-external"
  wait_rollout "kube-system" "external-coredns"
  wait_for_coredns_lb_ip

  apply_dir "03-external-dns"
  wait_rollout "kube-system" "external-dns"

  local coredns_ip
  coredns_ip="$(kubectl -n kube-system get svc external-coredns -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  local etcd_ip
  etcd_ip="$(kubectl -n kube-system get svc dns-etcd -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"

  step "Done (CoreDNS external DNS server is ready)"
  echo "external-coredns LB IP: ${coredns_ip:-<pending>}"
  echo "dns-etcd ClusterIP: ${etcd_ip:-<pending>}"
  echo "Run DNS test:"
  echo "  dig @${coredns_ip:-${DNS_SERVER}} test.hse-llm-project-2026.ru"
}

main "$@"
