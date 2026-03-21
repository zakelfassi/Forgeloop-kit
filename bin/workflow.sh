#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Forgeloop Workflow Lane (Experimental)
# =============================================================================
# Lists native workflow packs or runs workflow preflight/run through the managed
# Elixir babysitter/worktree path.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"
REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true

usage() {
  cat <<'USAGE'
Usage:
  ./forgeloop/bin/workflow.sh list
  ./forgeloop/bin/workflow.sh preflight <workflow-name>
  ./forgeloop/bin/workflow.sh run <workflow-name> [runner args...]

Notes:
  - This lane is experimental and manual-only.
  - Preflight/run now flow through the managed Elixir babysitter/worktree path.
  - Concurrent use with build/tasks/daemon is unsupported in this slice.
USAGE
}

list_workflows() {
  forgeloop_core__list_workflow_names "$REPO_DIR"
}

run_managed_workflow() {
  (
    cd "$FORGELOOP_DIR/elixir"
    mix forgeloop_v2.workflow --repo "$REPO_DIR" "$@"
  )
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
      run_managed_workflow preflight "$1"
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
      if [[ $# -gt 0 ]]; then
        run_managed_workflow run "$workflow_name" -- "$@"
      else
        run_managed_workflow run "$workflow_name"
      fi
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
