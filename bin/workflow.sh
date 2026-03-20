#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Forgeloop Workflow Lane (Experimental)
# =============================================================================
# Runs native Forgeloop workflow packs through Forgeloop's runtime-state and
# fail-closed escalation machinery.
#
# Usage:
#   ./forgeloop/bin/workflow.sh list
#   ./forgeloop/bin/workflow.sh preflight <workflow-name>
#   ./forgeloop/bin/workflow.sh run <workflow-name> [runner args...]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"
REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true

RUNTIME_DIR="$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")"
export FORGELOOP_RUNTIME_DIR="$RUNTIME_DIR"
LOG_FILE="${FORGELOOP_WORKFLOW_LOG_FILE:-$RUNTIME_DIR/logs/workflow.log}"
CURRENT_BRANCH="$(cd "$REPO_DIR" && forgeloop_core__git_current_branch)"

log() { forgeloop_core__log "$1" "$LOG_FILE"; }
notify() { forgeloop_core__notify "$REPO_DIR" "$@"; }

usage() {
  cat <<'USAGE'
Usage:
  ./forgeloop/bin/workflow.sh list
  ./forgeloop/bin/workflow.sh preflight <workflow-name>
  ./forgeloop/bin/workflow.sh run <workflow-name> [runner args...]

Notes:
  - This lane is experimental and manual-only.
  - It wraps a configured workflow runner.
  - Concurrent use with build/tasks/daemon is unsupported in this slice.
USAGE
}

list_workflows() {
  forgeloop_core__list_workflow_names "$REPO_DIR"
}

ensure_valid_workflow_name() {
  local workflow_name="$1"
  if ! forgeloop_core__validate_workflow_name "$workflow_name"; then
    echo "Error: invalid workflow name: $workflow_name" >&2
    return 1
  fi
}

ensure_workflow_exists() {
  local workflow_name="$1"
  local package_dir
  ensure_valid_workflow_name "$workflow_name" || return 1

  if ! package_dir="$(forgeloop_core__resolve_workflow_package_dir "$REPO_DIR" "$workflow_name")"; then
    echo "Error: workflow not found or incomplete: $workflow_name" >&2
    echo "Searched under:" >&2
    while IFS= read -r search_dir; do
      [[ -n "$search_dir" ]] || continue
      echo "  - $search_dir/$workflow_name" >&2
    done < <(forgeloop_core__workflow_search_dirs "$REPO_DIR")
    return 1
  fi

  echo "$package_dir"
}

WORKFLOW_ACTION_OUTPUT_FILE=""
WORKFLOW_ACTION_MODE=""
WORKFLOW_ACTION_FAILURE_KIND=""
WORKFLOW_ACTION_SUMMARY_PREFIX=""

workflow_action_metadata() {
  local action="$1"

  case "$action" in
    preflight)
      WORKFLOW_ACTION_OUTPUT_FILE="last-preflight.txt"
      WORKFLOW_ACTION_MODE="workflow-preflight"
      WORKFLOW_ACTION_FAILURE_KIND="workflow-preflight"
      WORKFLOW_ACTION_SUMMARY_PREFIX="Running workflow preflight"
      ;;
    run)
      WORKFLOW_ACTION_OUTPUT_FILE="last-run.txt"
      WORKFLOW_ACTION_MODE="workflow-run"
      WORKFLOW_ACTION_FAILURE_KIND="workflow-run"
      WORKFLOW_ACTION_SUMMARY_PREFIX="Running workflow"
      ;;
    *)
      return 1
      ;;
  esac
}

run_workflow_runner_capture() {
  local package_dir="$1"
  local output_file="$2"
  local state_root="$3"
  local runner="$4"
  shift 4

  local exit_code=0
  (
    cd "$package_dir"
    export FORGELOOP_WORKFLOW_STATE_ROOT="$state_root"
    "$runner" "$@"
  ) >"$output_file" 2>&1 || exit_code=$?
  return "$exit_code"
}

run_workflow_action() {
  local action="$1"
  local workflow_name="$2"
  shift 2
  local extra_args=("$@")

  local package_dir workflow_log_dir output_file workflow_state_root runtime_mode summary failure_kind runner
  package_dir="$(ensure_workflow_exists "$workflow_name")" || return 1
  workflow_log_dir="$(forgeloop_core__workflow_log_dir "$REPO_DIR" "$workflow_name")"

  if ! runner="$(forgeloop_core__resolve_workflow_runner)"; then
    output_file="$workflow_log_dir/last-${action}.txt"
    cat > "$output_file" <<EOF
workflow runner not found
Set FORGELOOP_WORKFLOW_RUNNER or install forgeloop-workflow.
EOF
    cat "$output_file"
    forgeloop_core__handle_repeated_failure "$REPO_DIR" "workflow-${action}" "workflow runner not found" "$output_file" "$LOG_FILE" "review" >/dev/null 2>&1 || true
    return 1
  fi

  workflow_state_root="$(forgeloop_core__resolve_workflow_state_root "$REPO_DIR")"
  mkdir -p "$workflow_state_root"

  workflow_action_metadata "$action" || {
    echo "Error: unsupported workflow action: $action" >&2
    return 1
  }
  output_file="$workflow_log_dir/$WORKFLOW_ACTION_OUTPUT_FILE"
  runtime_mode="$WORKFLOW_ACTION_MODE"
  failure_kind="$WORKFLOW_ACTION_FAILURE_KIND"
  summary="$WORKFLOW_ACTION_SUMMARY_PREFIX: $workflow_name"

  export FORGELOOP_RUNTIME_SURFACE="workflow"
  export FORGELOOP_RUNTIME_MODE="$runtime_mode"
  export FORGELOOP_RUNTIME_BRANCH="$CURRENT_BRANCH"

  forgeloop_core__set_runtime_state "$REPO_DIR" "running" "workflow" "$runtime_mode" "$summary" "$runtime_mode" "review" "$CURRENT_BRANCH"
  log "$summary"

  local runner_args=(run "$workflow_name")
  if [[ "$action" == "preflight" ]]; then
    runner_args=(run --preflight "$workflow_name")
  fi
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    runner_args+=("${extra_args[@]}")
  fi

  local exit_code=0
  run_workflow_runner_capture "$package_dir" "$output_file" "$workflow_state_root" "$runner" "${runner_args[@]}" || exit_code=$?

  if [[ -f "$output_file" ]]; then
    cat "$output_file"
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    forgeloop_core__clear_failure_state "$REPO_DIR"
    forgeloop_core__set_runtime_state "$REPO_DIR" "idle" "workflow" "$runtime_mode" "$action completed for workflow $workflow_name" "completed" "" "$CURRENT_BRANCH"
    notify "🧭" "Forgeloop Workflow Completed" "$workflow_name ($action) completed"
    return 0
  fi

  if forgeloop_core__handle_repeated_failure "$REPO_DIR" "$failure_kind" "$summary" "$output_file" "$LOG_FILE" "review"; then
    return 1
  fi

  return 1
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)
      shift
      list_workflows
      ;;
    preflight)
      shift
      if [[ $# -lt 1 ]]; then
        echo "Error: workflow name required for preflight" >&2
        usage
        exit 1
      fi
      run_workflow_action preflight "$1"
      ;;
    run)
      shift
      if [[ $# -lt 1 ]]; then
        echo "Error: workflow name required for run" >&2
        usage
        exit 1
      fi
      local workflow_name="$1"
      shift
      run_workflow_action run "$workflow_name" "$@"
      ;;
    ""|-h|--help)
      usage
      ;;
    *)
      echo "Error: unknown workflow command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
