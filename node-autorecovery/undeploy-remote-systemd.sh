#!/bin/bash
set -euo pipefail

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
SSH_OPTS="${SSH_OPTS:-}"
USE_SUDO_ON_REMOTE="${USE_SUDO_ON_REMOTE:-auto}" # auto|true|false
SERVICE_NAME="${SERVICE_NAME:-node-autoheal}"
REMOTE_BASE_DIR="${REMOTE_BASE_DIR:-}"
REMOVE_REMOTE_DIR="${REMOVE_REMOTE_DIR:-false}"

log() {
  echo "[node-autoheal-remote] $*"
}

is_true() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$raw" == "1" || "$raw" == "true" || "$raw" == "yes" || "$raw" == "on" ]]
}

if [[ -z "$REMOTE_HOST" ]]; then
  echo "[node-autoheal-remote] ERROR: set REMOTE_HOST." >&2
  exit 1
fi

if [[ -z "$REMOTE_BASE_DIR" ]]; then
  if [[ "$REMOTE_USER" == "root" ]]; then
    REMOTE_BASE_DIR="/root/node-autoheal"
  else
    REMOTE_BASE_DIR="/home/${REMOTE_USER}/node-autoheal"
  fi
fi

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

read -r -a SSH_OPTS_ARR <<< "$SSH_OPTS"
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_BASE=(ssh "${SSH_OPTS_ARR[@]}" -p "$REMOTE_PORT" "$SSH_TARGET")

UNINSTALL_CMD="cd '$REMOTE_BASE_DIR' && env SYSTEMD_SCOPE=system SERVICE_NAME='$SERVICE_NAME' ./uninstall-systemd.sh"
if [[ -n "$REMOTE_SUDO" ]]; then
  "${SSH_BASE[@]}" "${REMOTE_SUDO} bash -lc \"$UNINSTALL_CMD\" || true"
else
  "${SSH_BASE[@]}" "bash -lc \"$UNINSTALL_CMD\" || true"
fi

if is_true "$REMOVE_REMOTE_DIR"; then
  if [[ -n "$REMOTE_SUDO" ]]; then
    "${SSH_BASE[@]}" "${REMOTE_SUDO} rm -rf '$REMOTE_BASE_DIR'"
  else
    "${SSH_BASE[@]}" "rm -rf '$REMOTE_BASE_DIR'"
  fi
  log "Removed remote directory: $REMOTE_BASE_DIR"
fi

log "Remote undeploy finished for $SSH_TARGET."
