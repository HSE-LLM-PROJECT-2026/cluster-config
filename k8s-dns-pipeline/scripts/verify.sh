#!/bin/bash
set -euo pipefail

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo -e "${GREEN}[PASS]${NC} $*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo -e "${RED}[FAIL]${NC} $*"
}

step() {
  echo -e "${YELLOW}== $* ==${NC}"
}

check_pods_ready() {
  local component="$1"
  local label_selector="$2"

  if ! kubectl -n kube-system get pods -l "${label_selector}" --no-headers 2>/dev/null | grep -q .; then
    fail "${component}: no pods found"
    return
  fi

  if kubectl -n kube-system wait --for=condition=Ready pod -l "${label_selector}" --timeout=60s >/dev/null 2>&1; then
    pass "${component}: pods are Ready"
  else
    fail "${component}: pods are not Ready"
  fi
}

check_dns_record() {
  local dns_server="10.42.0.10"
  local fqdn="test.hse-llm-project-2026.ru"

  if ! command -v dig >/dev/null 2>&1; then
    fail "dig is not installed, cannot validate DNS"
    return
  fi

  local dig_raw
  dig_raw="$(dig @"${dns_server}" "${fqdn}" A +time=2 +tries=1 2>&1 || true)"
  local dig_short
  dig_short="$(dig @"${dns_server}" "${fqdn}" A +short +time=2 +tries=1 2>/dev/null || true)"

  echo "dig @${dns_server} ${fqdn}"
  echo "${dig_raw}"

  if echo "${dig_raw}" | grep -qiE "connection timed out|no servers could be reached"; then
    fail "DNS query failed: external CoreDNS is unreachable"
    return
  fi

  if [[ -n "${dig_short}" ]]; then
    pass "DNS record exists: ${fqdn} -> ${dig_short//$'\n'/, }"
  else
    fail "DNS record missing for ${fqdn} (create route/service first)"
  fi
}

main() {
  step "Verify pods in kube-system"
  check_pods_ready "etcd" "app.kubernetes.io/name=dns-etcd"
  check_pods_ready "coredns-external" "app.kubernetes.io/name=external-coredns"
  check_pods_ready "external-dns" "app.kubernetes.io/name=external-dns"

  step "Verify DNS query"
  check_dns_record

  step "Summary"
  echo "PASS: ${PASS_COUNT}"
  echo "FAIL: ${FAIL_COUNT}"

  if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
