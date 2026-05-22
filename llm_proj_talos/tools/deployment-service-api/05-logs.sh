#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

TAIL_LINES="${TAIL_LINES:-200}"
FOLLOW="${FOLLOW:-true}"

validate_env

log "Namespace: $NAMESPACE"
log "Deployment: $DEPLOYMENT_NAME"
log "Kubeconfig: $KUBECONFIG_PATH"

if [[ "$FOLLOW" == "true" ]]; then
  kctl logs -n "$NAMESPACE" "deployment/${DEPLOYMENT_NAME}" -f --tail="$TAIL_LINES"
else
  kctl logs -n "$NAMESPACE" "deployment/${DEPLOYMENT_NAME}" --tail="$TAIL_LINES"
fi
