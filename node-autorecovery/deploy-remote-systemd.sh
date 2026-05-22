#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"
USE_SUDO_ON_REMOTE="${USE_SUDO_ON_REMOTE:-auto}" # auto|true|false

if [[ -z "${REMOTE_BASE_DIR:-}" ]]; then
  if [[ "$REMOTE_USER" == "root" ]]; then
    REMOTE_BASE_DIR="/root/node-autoheal"
  else
    REMOTE_BASE_DIR="/home/${REMOTE_USER}/node-autoheal"
  fi
fi
REMOTE_CONFIG_DIR="${REMOTE_CONFIG_DIR:-${REMOTE_BASE_DIR}/config}"
REMOTE_STATE_DIR="${REMOTE_STATE_DIR:-${REMOTE_BASE_DIR}/.state}"
REMOTE_KUBECONFIG_PATH="${REMOTE_KUBECONFIG_PATH:-${REMOTE_CONFIG_DIR}/kubeconfig}"
REMOTE_TALOSCONFIG_PATH="${REMOTE_TALOSCONFIG_PATH:-${REMOTE_CONFIG_DIR}/talosconfig}"

LOCAL_KUBECONFIG_PATH="${LOCAL_KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
LOCAL_TALOSCONFIG_PATH="${LOCAL_TALOSCONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/talosconfig}"
LOCAL_ENV_FILE="${LOCAL_ENV_FILE:-}"
DISABLE_LOCAL_AUTORUN="${DISABLE_LOCAL_AUTORUN:-true}"

SERVICE_NAME="${SERVICE_NAME:-node-autoheal}"

log() {
  echo "[node-autoheal-remote] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[node-autoheal-remote] ERROR: command not found: $1" >&2
    exit 1
  }
}

is_true() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$raw" == "1" || "$raw" == "true" || "$raw" == "yes" || "$raw" == "on" ]]
}

upsert_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

need_cmd ssh
need_cmd scp
need_cmd mktemp

if [[ -z "$REMOTE_HOST" ]]; then
  echo "[node-autoheal-remote] ERROR: set REMOTE_HOST (example: REMOTE_HOST=10.19.87.2)." >&2
  exit 1
fi

[[ -f "$LOCAL_KUBECONFIG_PATH" ]] || {
  echo "[node-autoheal-remote] ERROR: kubeconfig not found: $LOCAL_KUBECONFIG_PATH" >&2
  exit 1
}
[[ -f "$LOCAL_TALOSCONFIG_PATH" ]] || {
  echo "[node-autoheal-remote] ERROR: talosconfig not found: $LOCAL_TALOSCONFIG_PATH" >&2
  exit 1
}

ENV_SRC="$LOCAL_ENV_FILE"
if [[ -z "$ENV_SRC" ]]; then
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    ENV_SRC="$SCRIPT_DIR/.env"
  else
    ENV_SRC="$SCRIPT_DIR/.env.example"
  fi
fi
[[ -f "$ENV_SRC" ]] || {
  echo "[node-autoheal-remote] ERROR: env source not found: $ENV_SRC" >&2
  exit 1
}

read -r -a SSH_OPTS_ARR <<< "$SSH_OPTS"
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_BASE=(ssh "${SSH_OPTS_ARR[@]}" -p "$REMOTE_PORT" "$SSH_TARGET")
SCP_BASE=(scp "${SSH_OPTS_ARR[@]}" -P "$REMOTE_PORT")

if [[ "$USE_SUDO_ON_REMOTE" == "auto" ]]; then
  if [[ "$REMOTE_USER" == "root" ]]; then
    REMOTE_SUDO=""
  else
    REMOTE_SUDO="sudo"
  fi
elif is_true "$USE_SUDO_ON_REMOTE"; then
  REMOTE_SUDO="sudo"
else
  REMOTE_SUDO=""
fi

TMP_ENV="$(mktemp)"
trap 'rm -f "$TMP_ENV"' EXIT
cp "$ENV_SRC" "$TMP_ENV"

upsert_env_key "$TMP_ENV" "KUBECONFIG_PATH" "$REMOTE_KUBECONFIG_PATH"
upsert_env_key "$TMP_ENV" "TALOSCONFIG_PATH" "$REMOTE_TALOSCONFIG_PATH"
upsert_env_key "$TMP_ENV" "STATE_DIR" "$REMOTE_STATE_DIR"

log "Remote target: $SSH_TARGET"
log "Remote base dir: $REMOTE_BASE_DIR"
log "Remote config dir: $REMOTE_CONFIG_DIR"
log "Using sudo on remote: ${REMOTE_SUDO:+yes}${REMOTE_SUDO:+" (sudo)"}${REMOTE_SUDO:-no}"

"${SSH_BASE[@]}" "\
  set -euo pipefail; \
  ${REMOTE_SUDO:+$REMOTE_SUDO }mkdir -p '$REMOTE_BASE_DIR' '$REMOTE_CONFIG_DIR' '$REMOTE_STATE_DIR'; \
  if [ -n '${REMOTE_SUDO}' ]; then ${REMOTE_SUDO} chown -R '$REMOTE_USER':'$REMOTE_USER' '$REMOTE_BASE_DIR'; fi"

"${SCP_BASE[@]}" \
  "$SCRIPT_DIR/node-autoheal.sh" \
  "$SCRIPT_DIR/install-systemd.sh" \
  "$SCRIPT_DIR/uninstall-systemd.sh" \
  "$TMP_ENV" \
  "$SSH_TARGET:$REMOTE_BASE_DIR/"

"${SCP_BASE[@]}" \
  "$LOCAL_KUBECONFIG_PATH" \
  "$LOCAL_TALOSCONFIG_PATH" \
  "$SSH_TARGET:$REMOTE_CONFIG_DIR/"

"${SSH_BASE[@]}" "\
  set -euo pipefail; \
  mv '$REMOTE_BASE_DIR/$(basename "$TMP_ENV")' '$REMOTE_BASE_DIR/.env'; \
  chmod +x '$REMOTE_BASE_DIR/'*.sh"

CHECK_REMOTE_CMDS="command -v kubectl >/dev/null && command -v talosctl >/dev/null && command -v systemctl >/dev/null"
if ! "${SSH_BASE[@]}" "$CHECK_REMOTE_CMDS"; then
  echo "[node-autoheal-remote] ERROR: remote host misses required commands (kubectl/talosctl/systemctl)." >&2
  exit 1
fi

INSTALL_CMD="cd '$REMOTE_BASE_DIR' && env SYSTEMD_SCOPE=system SERVICE_NAME='$SERVICE_NAME' ./install-systemd.sh"
STATUS_CMD="systemctl status '${SERVICE_NAME}.timer' --no-pager -l | sed -n '1,40p'"
if [[ -n "$REMOTE_SUDO" ]]; then
  "${SSH_BASE[@]}" "${REMOTE_SUDO} bash -lc \"$INSTALL_CMD\""
  "${SSH_BASE[@]}" "${REMOTE_SUDO} bash -lc \"$STATUS_CMD\""
else
  "${SSH_BASE[@]}" "bash -lc \"$INSTALL_CMD\""
  "${SSH_BASE[@]}" "bash -lc \"$STATUS_CMD\""
fi

if is_true "$DISABLE_LOCAL_AUTORUN"; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 || true
    systemctl --user stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    log "Local user timer disabled on this machine (${SERVICE_NAME}.timer)."
  fi
fi

log "Remote deployment finished."
log "To inspect logs: ssh -p $REMOTE_PORT $SSH_TARGET '${REMOTE_SUDO:+$REMOTE_SUDO }journalctl -u ${SERVICE_NAME}.service -f'"
