#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

delete_dir() {
  local dir="$1"
  step "Delete ${dir}"
  if kubectl delete -f "${ROOT_DIR}/${dir}" --ignore-not-found=true; then
    ok "Deleted ${dir}"
  else
    fail "Failed to delete ${dir}"
    return 1
  fi
}

main() {
  delete_dir "05-metallb-patch"
  delete_dir "04-gateway"
  delete_dir "03-external-dns"
  delete_dir "02-coredns-external"
  delete_dir "01-etcd"
  delete_dir "00-namespace"
  ok "DNS pipeline resources removed"
}

main "$@"
