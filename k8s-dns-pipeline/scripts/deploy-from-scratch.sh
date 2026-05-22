#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common.sh"

log "Starting deploy from scratch"
log "Env file: $ENV_FILE"
log "Kubeconfig: $KUBECONFIG_PATH"

need_cmd kubectl
need_cmd bash
require_kubeconfig

bash "$SCRIPT_DIR/deploy-all.sh"

log "Deploy from scratch finished"
