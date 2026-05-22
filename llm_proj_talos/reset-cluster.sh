#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${SCRIPT_DIR}/../llm_proj_terraform}"
GENERATED_DIR="${SCRIPT_DIR}/generated"
VPN_KEYS_DIR="${SCRIPT_DIR}/vpn-keys"

AUTO_YES=false
if [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; then
  AUTO_YES=true
fi

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: command not found: $cmd" >&2
    exit 1
  fi
}

require_command terraform

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "ERROR: terraform dir not found: ${TERRAFORM_DIR}" >&2
  exit 1
fi

echo "This will fully recreate VM infrastructure from: ${TERRAFORM_DIR}"

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Continue? (y/N): " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Cancelled"
    exit 0
  fi
fi

echo "== terraform init =="
terraform -chdir="${TERRAFORM_DIR}" init -input=false

echo "== terraform destroy =="
terraform -chdir="${TERRAFORM_DIR}" destroy -auto-approve

echo "== terraform apply =="
terraform -chdir="${TERRAFORM_DIR}" apply -auto-approve

echo "== cleanup local Talos artifacts =="
rm -f "${SCRIPT_DIR}/kubeconfig"
rm -rf "${GENERATED_DIR}"
rm -rf "${VPN_KEYS_DIR}"
mkdir -p "${GENERATED_DIR}" "${VPN_KEYS_DIR}"

cat > "${GENERATED_DIR}/vm-ips-template.txt" <<'TEMPLATE'
# Fill real Talos management IPs, then run ./set-vm-ips.sh
# Expected names:
# cp
# worker-1
# gpu-worker-v100
# worker-2
# Optional (only if APPLY_WORKER_3=true in .env):
# worker-3
TEMPLATE

echo "Done. VM infrastructure is recreated."
echo "Next step 1: update management IPs in ${SCRIPT_DIR}/.env"
echo "Next step 2: prepare WireGuard peers on the VPN server"
echo "Next step 3: cd ${SCRIPT_DIR} && ./bootstrap.sh"
