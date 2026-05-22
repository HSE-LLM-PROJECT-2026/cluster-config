#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <deployment-id>" >&2
  exit 1
fi

DEPLOYMENT_ID="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

validate_env
start_temporary_port_forward

curl_api "/deployments/${DEPLOYMENT_ID}" | pretty_json
