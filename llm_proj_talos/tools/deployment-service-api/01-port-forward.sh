#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

validate_env

log "Starting port-forward"
log "Namespace: $NAMESPACE"
log "Deployment: $DEPLOYMENT_NAME"
log "Kubeconfig: $KUBECONFIG_PATH"
log "Local port: $LOCAL_PORT -> Remote port: $REMOTE_PORT"

kctl -n "$NAMESPACE" port-forward "deployment/${DEPLOYMENT_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}"
