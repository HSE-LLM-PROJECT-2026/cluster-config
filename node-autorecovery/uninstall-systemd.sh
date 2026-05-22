#!/bin/bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-node-autoheal}"
SYSTEMD_SCOPE="${SYSTEMD_SCOPE:-user}" # user|system

log() {
  echo "[node-autoheal] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[node-autoheal] ERROR: command not found: $1" >&2
    exit 1
  }
}

need_cmd systemctl

if [[ "$SYSTEMD_SCOPE" == "system" ]]; then
  UNIT_DIR="/etc/systemd/system"
  SYSTEMCTL=(systemctl)
else
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  SYSTEMCTL=(systemctl --user)
fi

SERVICE_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
TIMER_FILE="${UNIT_DIR}/${SERVICE_NAME}.timer"

"${SYSTEMCTL[@]}" disable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 || true
"${SYSTEMCTL[@]}" disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

rm -f "$SERVICE_FILE" "$TIMER_FILE"
"${SYSTEMCTL[@]}" daemon-reload

log "Removed unit files:"
log "  ${SERVICE_FILE}"
log "  ${TIMER_FILE}"

