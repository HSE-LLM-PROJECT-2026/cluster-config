#!/bin/bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <NAME> <PORT> [NAMESPACE]"
  exit 1
fi

NAME="$1"
PORT="$2"
NAMESPACE="${3:-default}"
DOMAIN="hse-llm-project-2026.ru"
HOSTNAME="${NAME}.${DOMAIN}"
ROUTE_NAME="${NAME}-route"
GATEWAY_NAME="web-gateway"
GATEWAY_NAMESPACE="${NAMESPACE}"
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

if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
  fail "PORT must be numeric"
  exit 1
fi

if ! kubectl -n "${NAMESPACE}" get service "${NAME}" >/dev/null 2>&1; then
  fail "Service ${NAMESPACE}/${NAME} not found"
  exit 1
fi

if ! kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" >/dev/null 2>&1; then
  step "Gateway ${GATEWAY_NAMESPACE}/${GATEWAY_NAME} not found, creating it"
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${GATEWAY_NAME}
    app.kubernetes.io/component: gateway
    app.kubernetes.io/managed-by: dns-pipeline
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
EOF
  ok "Gateway created in namespace ${GATEWAY_NAMESPACE}"
fi

step "Apply HTTPRoute ${NAMESPACE}/${ROUTE_NAME}"
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${ROUTE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${ROUTE_NAME}
    app.kubernetes.io/component: route
    app.kubernetes.io/managed-by: dns-pipeline
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      sectionName: http
  hostnames:
    - ${HOSTNAME}
  rules:
    - backendRefs:
        - name: ${NAME}
          port: ${PORT}
EOF
ok "HTTPRoute applied"

step "Wait for Gateway IP"
GATEWAY_IP=""
for _ in $(seq 1 30); do
  GATEWAY_IP="$(kubectl -n "${GATEWAY_NAMESPACE}" get gateway "${GATEWAY_NAME}" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  if [[ -n "${GATEWAY_IP}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${GATEWAY_IP}" ]]; then
  fail "Gateway IP is not assigned yet"
  exit 1
fi
ok "Gateway IP: ${GATEWAY_IP}"

if command -v dig >/dev/null 2>&1; then
  step "Check DNS propagation"
  DNS_RESULT="$(dig @"${DNS_SERVER}" "${HOSTNAME}" A +short +time=2 +tries=1 2>/dev/null || true)"
  if [[ -n "${DNS_RESULT}" ]]; then
    ok "DNS record: ${HOSTNAME} -> ${DNS_RESULT//$'\n'/, }"
  else
    echo "DNS record is not visible yet via ${DNS_SERVER}; wait a bit and run:"
    echo "  dig @${DNS_SERVER} ${HOSTNAME} A +short"
  fi
fi

echo "URL: http://${HOSTNAME}"
