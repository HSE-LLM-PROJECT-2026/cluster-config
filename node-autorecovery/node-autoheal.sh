#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/kubeconfig}"
TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-/home/oleg/Documents/hse-llm-project/cluster-config/llm_proj_talos/talosconfig}"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.state}"
TARGET_NODE_REGEX="${TARGET_NODE_REGEX:-^(worker-|gpu-worker-).*}"
NOT_READY_THRESHOLD_SECONDS="${NOT_READY_THRESHOLD_SECONDS:-300}"
REBOOT_COOLDOWN_SECONDS="${REBOOT_COOLDOWN_SECONDS:-1800}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-120}"
MAX_REBOOTS_PER_RUN="${MAX_REBOOTS_PER_RUN:-1}"
SKIP_CONTROL_PLANE="${SKIP_CONTROL_PLANE:-true}"
DELETE_TERMINATING_PODS="${DELETE_TERMINATING_PODS:-true}"
AUTO_UNCORDON="${AUTO_UNCORDON:-true}"
CHECK_ONLY="${CHECK_ONLY:-false}"
REQUIRE_STATUS_COLUMN_NOTREADY="${REQUIRE_STATUS_COLUMN_NOTREADY:-true}"
SKIP_AMBIGUOUS_READY_CONDITIONS="${SKIP_AMBIGUOUS_READY_CONDITIONS:-true}"
MAX_CLUSTER_REBOOTS_PER_WINDOW="${MAX_CLUSTER_REBOOTS_PER_WINDOW:-2}"
CLUSTER_REBOOT_WINDOW_SECONDS="${CLUSTER_REBOOT_WINDOW_SECONDS:-3600}"
MIN_READY_TARGET_NODES="${MIN_READY_TARGET_NODES:-2}"
API_SERVER_READY_REQUIRED="${API_SERVER_READY_REQUIRED:-true}"
API_SERVER_READY_TIMEOUT_SECONDS="${API_SERVER_READY_TIMEOUT_SECONDS:-7}"
MIN_TARGET_NODE_VISIBILITY="${MIN_TARGET_NODE_VISIBILITY:-2}"
SKIP_IF_HIGH_NOTREADY_PERCENT="${SKIP_IF_HIGH_NOTREADY_PERCENT:-true}"
HIGH_NOTREADY_PERCENT_THRESHOLD="${HIGH_NOTREADY_PERCENT_THRESHOLD:-80}"

log() {
  echo "[node-autoheal] $*"
}

warn() {
  echo "[node-autoheal] WARN: $*" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[node-autoheal] ERROR: command not found: $1" >&2
    exit 1
  }
}

is_true() {
  local raw
  raw="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$raw" == "1" || "$raw" == "true" || "$raw" == "yes" || "$raw" == "on" ]]
}

jsonpath_node() {
  local node_name="$1"
  local path="$2"
  kubectl get node "$node_name" -o "jsonpath=$path" 2>/dev/null || true
}

node_status_column() {
  local node_name="$1"
  kubectl get node "$node_name" --no-headers 2>/dev/null | awk '{print $2}' || true
}

node_is_control_plane() {
  local node_name="$1"
  local cp_label
  local master_label
  cp_label="$(jsonpath_node "$node_name" '{.metadata.labels.node-role\.kubernetes\.io/control-plane}')"
  master_label="$(jsonpath_node "$node_name" '{.metadata.labels.node-role\.kubernetes\.io/master}')"
  [[ -n "$cp_label" || -n "$master_label" ]]
}

cleanup_terminating_pods() {
  local node_name="$1"
  local line
  local namespace
  local pod_name
  local deletion_ts
  local deleted=0

  while IFS=$'\t' read -r namespace pod_name deletion_ts; do
    [[ -z "${namespace:-}" || -z "${pod_name:-}" ]] && continue
    [[ -z "${deletion_ts:-}" ]] && continue
    log "Force deleting terminating pod: ${namespace}/${pod_name}"
    kubectl -n "$namespace" delete pod "$pod_name" --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
    deleted=$((deleted + 1))
  done < <(
    kubectl get pods -A \
      --field-selector "spec.nodeName=${node_name}" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}'
  )

  if (( deleted > 0 )); then
    log "Deleted terminating pods on ${node_name}: ${deleted}"
  fi
}

drain_node() {
  local node_name="$1"
  local timeout_s="$2"
  timeout "${timeout_s}s" kubectl drain "$node_name" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --disable-eviction \
    --grace-period=30 \
    --timeout="${timeout_s}s" >/dev/null 2>&1 || true
}

count_ready_target_nodes() {
  local count=0
  while read -r line; do
    [[ -z "${line:-}" ]] && continue
    local node_name
    local status_col
    node_name="$(echo "$line" | awk '{print $1}')"
    status_col="$(echo "$line" | awk '{print $2}')"
    [[ "$node_name" =~ $TARGET_NODE_REGEX ]] || continue
    if [[ "$status_col" == *"NotReady"* ]]; then
      continue
    fi
    if [[ "$status_col" == *"Ready"* ]]; then
      count=$((count + 1))
    fi
  done < <(kubectl get nodes --no-headers 2>/dev/null || true)
  echo "$count"
}

cluster_reboot_budget_allows() {
  local now_epoch="$1"
  local log_file="${STATE_DIR}/.cluster_reboots.epoch"
  local min_epoch=$((now_epoch - CLUSTER_REBOOT_WINDOW_SECONDS))
  local kept_tmp
  kept_tmp="$(mktemp)"
  if [[ -f "$log_file" ]]; then
    awk -v min="$min_epoch" '$1 >= min {print $1}' "$log_file" > "$kept_tmp" || true
    mv "$kept_tmp" "$log_file"
  else
    : > "$log_file"
    rm -f "$kept_tmp"
  fi
  local used=0
  used="$(wc -l < "$log_file" | tr -d '[:space:]')"
  if (( used >= MAX_CLUSTER_REBOOTS_PER_WINDOW )); then
    return 1
  fi
  return 0
}

cluster_readyz_ok() {
  local output=""
  output="$(timeout "${API_SERVER_READY_TIMEOUT_SECONDS}s" kubectl get --raw='/readyz' 2>/dev/null || true)"
  [[ "$output" == *"ok"* ]]
}

collect_target_node_health() {
  local total=0
  local ready=0
  local notready=0
  local line

  while read -r line; do
    [[ -z "${line:-}" ]] && continue
    local node_name
    local status_col
    node_name="$(echo "$line" | awk '{print $1}')"
    status_col="$(echo "$line" | awk '{print $2}')"
    [[ "$node_name" =~ $TARGET_NODE_REGEX ]] || continue
    if is_true "$SKIP_CONTROL_PLANE" && node_is_control_plane "$node_name"; then
      continue
    fi
    total=$((total + 1))
    if [[ "$status_col" == *"NotReady"* ]]; then
      notready=$((notready + 1))
    elif [[ "$status_col" == *"Ready"* ]]; then
      ready=$((ready + 1))
    fi
  done < <(kubectl get nodes --no-headers 2>/dev/null || true)

  echo "${total} ${ready} ${notready}"
}

reboot_node_via_talos() {
  local node_name="$1"
  local node_ip="$2"

  if [[ -z "$node_ip" ]]; then
    warn "Node ${node_name} has no InternalIP, cannot run talosctl reboot."
    return 1
  fi
  if [[ ! -f "$TALOSCONFIG_PATH" ]]; then
    warn "talosconfig not found (${TALOSCONFIG_PATH}), skipping reboot for ${node_name}."
    return 1
  fi

  local output
  output="$(timeout 45s talosctl --talosconfig "$TALOSCONFIG_PATH" -n "$node_ip" reboot 2>&1)" || {
    local rc=$?
    if [[ $rc -eq 124 ]]; then
      warn "talosctl reboot timed out for ${node_name} (${node_ip}); it may still be in progress."
      return 0
    fi
    warn "talosctl reboot failed for ${node_name} (${node_ip}): ${output}"
    return 1
  }

  if [[ -n "$output" ]]; then
    log "talosctl reboot output for ${node_name}: ${output}"
  fi
  return 0
}

main() {
  need_cmd kubectl
  need_cmd talosctl
  need_cmd timeout
  need_cmd date

  [[ -f "$KUBECONFIG_PATH" ]] || {
    echo "[node-autoheal] ERROR: kubeconfig not found: ${KUBECONFIG_PATH}" >&2
    exit 1
  }
  export KUBECONFIG="$KUBECONFIG_PATH"

  mkdir -p "$STATE_DIR"

  log "Starting autoheal pass"
  log "kubeconfig=${KUBECONFIG_PATH}"
  log "talosconfig=${TALOSCONFIG_PATH}"
  log "target_regex=${TARGET_NODE_REGEX}"
  log "not_ready_threshold=${NOT_READY_THRESHOLD_SECONDS}s, reboot_cooldown=${REBOOT_COOLDOWN_SECONDS}s, max_reboots_per_run=${MAX_REBOOTS_PER_RUN}"
  log "cluster_reboot_budget=${MAX_CLUSTER_REBOOTS_PER_WINDOW}/${CLUSTER_REBOOT_WINDOW_SECONDS}s, min_ready_target_nodes=${MIN_READY_TARGET_NODES}"
  log "api_guard: ready_required=${API_SERVER_READY_REQUIRED}, ready_timeout=${API_SERVER_READY_TIMEOUT_SECONDS}s, min_visibility=${MIN_TARGET_NODE_VISIBILITY}, high_notready_guard=${SKIP_IF_HIGH_NOTREADY_PERCENT}>=${HIGH_NOTREADY_PERCENT_THRESHOLD}%"
  log "check_only=${CHECK_ONLY}"

  local now_epoch
  now_epoch="$(date -u +%s)"

  if is_true "$API_SERVER_READY_REQUIRED" && ! cluster_readyz_ok; then
    warn "Skip autoheal pass: Kubernetes API '/readyz' is not healthy/reachable."
    return 0
  fi

  local target_total
  local target_ready
  local target_notready
  read -r target_total target_ready target_notready <<< "$(collect_target_node_health)"
  if (( target_total < MIN_TARGET_NODE_VISIBILITY )); then
    warn "Skip autoheal pass: visible target nodes=${target_total} < MIN_TARGET_NODE_VISIBILITY=${MIN_TARGET_NODE_VISIBILITY}."
    return 0
  fi
  if (( target_ready == 0 )); then
    warn "Skip autoheal pass: no Ready target nodes visible (ready=0/${target_total})."
    return 0
  fi
  if is_true "$SKIP_IF_HIGH_NOTREADY_PERCENT"; then
    local notready_percent=0
    notready_percent=$((100 * target_notready / target_total))
    if (( notready_percent >= HIGH_NOTREADY_PERCENT_THRESHOLD )); then
      warn "Skip autoheal pass: high NotReady ratio among target nodes (${target_notready}/${target_total}=${notready_percent}%)."
      return 0
    fi
  fi

  local node_name
  local rebooted_count=0
  while read -r node_name; do
    [[ -z "$node_name" ]] && continue
    [[ "$node_name" =~ $TARGET_NODE_REGEX ]] || continue

    if is_true "$SKIP_CONTROL_PLANE" && node_is_control_plane "$node_name"; then
      continue
    fi

    local ready_status
    local ready_reason
    local ready_message
    local ready_transition
    local internal_ip
    local unschedulable
    local status_col
    ready_status="$(jsonpath_node "$node_name" '{.status.conditions[?(@.type=="Ready")].status}')"
    ready_reason="$(jsonpath_node "$node_name" '{.status.conditions[?(@.type=="Ready")].reason}')"
    ready_message="$(jsonpath_node "$node_name" '{.status.conditions[?(@.type=="Ready")].message}')"
    ready_transition="$(jsonpath_node "$node_name" '{.status.conditions[?(@.type=="Ready")].lastTransitionTime}')"
    internal_ip="$(jsonpath_node "$node_name" '{.status.addresses[?(@.type=="InternalIP")].address}')"
    unschedulable="$(jsonpath_node "$node_name" '{.spec.unschedulable}')"
    status_col="$(node_status_column "$node_name")"

    ready_status="$(echo "${ready_status:-}" | awk '{print $1}')"
    ready_reason="$(echo "${ready_reason:-}" | awk '{print $1}')"

    local state_file="${STATE_DIR}/${node_name}.last_reboot_epoch"

    if [[ "$ready_status" == "True" ]]; then
      if is_true "$AUTO_UNCORDON" && [[ "$unschedulable" == "true" && -f "$state_file" ]]; then
        if is_true "$CHECK_ONLY"; then
          log "CHECK_ONLY: would uncordon recovered node ${node_name}"
        else
          log "Node ${node_name} recovered, uncordon."
          kubectl uncordon "$node_name" >/dev/null 2>&1 || true
        fi
      fi
      continue
    fi

    if is_true "$REQUIRE_STATUS_COLUMN_NOTREADY" && [[ "$status_col" != *"NotReady"* ]]; then
      continue
    fi

    if is_true "$SKIP_AMBIGUOUS_READY_CONDITIONS"; then
      if [[ "$ready_status" != "False" && "$ready_status" != "Unknown" ]]; then
        warn "Skip ${node_name}: ambiguous Ready condition status='${ready_status:-empty}' (status_col='${status_col:-empty}')."
        continue
      fi
      if [[ "$ready_reason" == "KubeletReady" ]]; then
        warn "Skip ${node_name}: contradictory Ready reason='KubeletReady' while status='${ready_status}'."
        continue
      fi
    fi

    local transition_epoch=0
    if [[ -n "$ready_transition" ]]; then
      transition_epoch="$(date -u -d "$ready_transition" +%s 2>/dev/null || echo 0)"
    fi
    if (( transition_epoch <= 0 )); then
      warn "Skip ${node_name}: cannot parse Ready.lastTransitionTime='${ready_transition:-empty}'."
      continue
    fi
    local not_ready_for=$((now_epoch - transition_epoch))
    if (( transition_epoch > 0 && not_ready_for < NOT_READY_THRESHOLD_SECONDS )); then
      continue
    fi

    local last_reboot_epoch=0
    if [[ -f "$state_file" ]]; then
      last_reboot_epoch="$(cat "$state_file" 2>/dev/null || echo 0)"
    fi
    if (( last_reboot_epoch > 0 && (now_epoch - last_reboot_epoch) < REBOOT_COOLDOWN_SECONDS )); then
      log "Skip ${node_name}: cooldown active (last reboot $((now_epoch - last_reboot_epoch))s ago)."
      continue
    fi

    if (( rebooted_count >= MAX_REBOOTS_PER_RUN )); then
      warn "Reached MAX_REBOOTS_PER_RUN=${MAX_REBOOTS_PER_RUN}, skipping remaining nodes."
      break
    fi
    if ! cluster_reboot_budget_allows "$now_epoch"; then
      warn "Cluster reboot budget exceeded: max ${MAX_CLUSTER_REBOOTS_PER_WINDOW} reboots per ${CLUSTER_REBOOT_WINDOW_SECONDS}s."
      break
    fi

    local ready_target_nodes
    ready_target_nodes="$(count_ready_target_nodes)"
    if (( ready_target_nodes <= MIN_READY_TARGET_NODES )); then
      warn "Skip ${node_name}: ready target nodes=${ready_target_nodes} <= MIN_READY_TARGET_NODES=${MIN_READY_TARGET_NODES}."
      continue
    fi

    log "Autohealing node ${node_name}: Ready=${ready_status:-Unknown}, reason=${ready_reason:-n/a}, message=${ready_message:-n/a}"

    if is_true "$CHECK_ONLY"; then
      log "CHECK_ONLY: would cordon/drain/cleanup/reboot ${node_name}"
      continue
    fi

    kubectl cordon "$node_name" >/dev/null 2>&1 || true
    drain_node "$node_name" "$DRAIN_TIMEOUT_SECONDS"
    if is_true "$DELETE_TERMINATING_PODS"; then
      cleanup_terminating_pods "$node_name"
    fi

    if reboot_node_via_talos "$node_name" "$internal_ip"; then
      echo "$now_epoch" > "$state_file"
      echo "$now_epoch" >> "${STATE_DIR}/.cluster_reboots.epoch"
      rebooted_count=$((rebooted_count + 1))
      log "Reboot initiated for ${node_name} (${internal_ip})."
    fi
  done < <(kubectl get nodes -o name 2>/dev/null | cut -d/ -f2)

  log "Autoheal pass finished. reboot_attempts=${rebooted_count}"
}

main "$@"
