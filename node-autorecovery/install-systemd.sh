#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="${SERVICE_NAME:-node-autoheal}"
TIMER_INTERVAL="${TIMER_INTERVAL:-60s}"
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

mkdir -p "$UNIT_DIR"

SERVICE_FILE="${UNIT_DIR}/${SERVICE_NAME}.service"
TIMER_FILE="${UNIT_DIR}/${SERVICE_NAME}.timer"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Talos node autoheal watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
Environment=ENV_FILE=${SCRIPT_DIR}/.env
ExecStart=/usr/bin/env bash ${SCRIPT_DIR}/node-autoheal.sh
EOF

cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Talos node autoheal watchdog periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=${TIMER_INTERVAL}
Unit=${SERVICE_NAME}.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

log "Installed unit files:"
log "  ${SERVICE_FILE}"
log "  ${TIMER_FILE}"

"${SYSTEMCTL[@]}" daemon-reload
"${SYSTEMCTL[@]}" enable --now "${SERVICE_NAME}.timer"
"${SYSTEMCTL[@]}" status "${SERVICE_NAME}.timer" --no-pager || true

log "Autoheal timer enabled (${SYSTEMD_SCOPE} scope, interval=${TIMER_INTERVAL})."

