#!/bin/bash
set -euo pipefail

# =============================================================================
# Forgeloop Loop (Portable)
# =============================================================================
# Runs an agent loop using Claude and/or Codex CLIs with task-based routing.
#
# Usage:
#   ./forgeloop/bin/loop.sh [plan] [max_iterations] [--watch|--infinite]
#   ./forgeloop/bin/loop.sh plan-work "work description" [max_iterations] [--watch|--infinite]
#   ./forgeloop/bin/loop.sh review
#   ./forgeloop/bin/loop.sh [max_iterations] [--watch|--infinite]
#
# Config:
#   See `forgeloop/config.sh` (autopush off by default).
# =============================================================================

# Resolve repo directory and load libraries
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FORGELOOP_DIR="$REPO_DIR/forgeloop"
if [[ ! -f "$FORGELOOP_DIR/lib/core.sh" ]]; then
    FORGELOOP_DIR="$REPO_DIR"
fi
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true
source "$FORGELOOP_DIR/lib/core.sh"
source "$FORGELOOP_DIR/lib/llm.sh"

# Setup runtime directories and paths
RUNTIME_DIR=$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")
export FORGELOOP_RUNTIME_DIR="$RUNTIME_DIR"
LOG_FILE="${FORGELOOP_LOOP_LOG_FILE:-$RUNTIME_DIR/logs/loop.log}"
STATE_FILE="$RUNTIME_DIR/state"

REVIEW_SCHEMA="${FORGELOOP_REVIEW_SCHEMA:-$REPO_DIR/forgeloop/schemas/review.schema.json}"
SECURITY_SCHEMA="${FORGELOOP_SECURITY_SCHEMA:-$REPO_DIR/forgeloop/schemas/security.schema.json}"

PROMPT_PLAN="${FORGELOOP_PROMPT_PLAN:-PROMPT_plan.md}"
PROMPT_BUILD="${FORGELOOP_PROMPT_BUILD:-PROMPT_build.md}"
PROMPT_PLAN_WORK="${FORGELOOP_PROMPT_PLAN_WORK:-PROMPT_plan_work.md}"

# Convenience wrappers using library functions
log() { forgeloop_core__log "$1" "$LOG_FILE"; }
notify() { forgeloop_core__notify "$REPO_DIR" "$@"; }

run_verify_cmd() {
    local cmd="$1"
    if [[ -z "$cmd" ]]; then
        return 0
    fi

    local verify_dir="$RUNTIME_DIR/verify"
    mkdir -p "$verify_dir"
    local verify_out="$verify_dir/verify-last.txt"

    log "Running verify command: $cmd"
    local exit_code=0
    forgeloop_core__run_cmd_capture "$REPO_DIR" "$cmd" "$verify_out" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        local untrusted_file="$verify_dir/verify-last.untrusted.md"
        local max_chars="${FORGELOOP_UNTRUSTED_CONTEXT_MAX_CHARS:-20000}"
        forgeloop_core__wrap_untrusted_context "Verify Command Failure Output" "$verify_out" "$untrusted_file" "$max_chars" || true
        forgeloop_core__append_extra_context_file "$untrusted_file"
        log "Verify command failed; skipping CI gate and push"
        return 1
    fi

    log "Verify command passed"
    return 0
}

# Select AGENTS file based on FORGELOOP_LITE mode
if [[ "${FORGELOOP_LITE:-false}" == "true" ]]; then
    export FORGELOOP_AGENTS_FILE="AGENTS-lite.md"
    if [[ -f "$REPO_DIR/AGENTS-lite.md" ]]; then
        log "Using lite mode: AGENTS-lite.md"
    else
        log "Warning: AGENTS-lite.md not found, falling back to AGENTS.md"
        export FORGELOOP_AGENTS_FILE="AGENTS.md"
    fi
else
    export FORGELOOP_AGENTS_FILE="AGENTS.md"
fi

# =============================================================================
# Arg parsing
# =============================================================================

MODE="build"
PROMPT_FILE="$PROMPT_BUILD"
MAX_ITERATIONS=10
INFINITE=false

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch|--infinite)
            INFINITE=true
            shift
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
set -- "${args[@]:-}"

if [ "${1:-}" = "plan" ]; then
    MODE="plan"
    PROMPT_FILE="$PROMPT_PLAN"
    MAX_ITERATIONS=${2:-1}
elif [ "${1:-}" = "plan-work" ]; then
    if [ -z "${2:-}" ]; then
        echo "Error: plan-work requires a work description"
        echo "Usage: ./forgeloop/bin/loop.sh plan-work \"description\" [max_iterations]"
        exit 1
    fi
    MODE="plan-work"
    WORK_DESCRIPTION="$2"
    PROMPT_FILE="$PROMPT_PLAN_WORK"
    MAX_ITERATIONS=${3:-3}
elif [ "${1:-}" = "review" ]; then
    MODE="review"
    MAX_ITERATIONS=1
elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=$1
fi

if [[ "$INFINITE" == "true" ]]; then
    MAX_ITERATIONS=0
fi

ITERATION=0
CURRENT_BRANCH=$(forgeloop_core__git_current_branch)

if [ "$MODE" = "plan-work" ]; then
    if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
        echo "Error: plan-work should be run on a work branch, not main/master"
        exit 1
    fi
    export WORK_SCOPE="$WORK_DESCRIPTION"
fi

export MODE

cd "$REPO_DIR"
forgeloop_llm__load_state "$STATE_FILE"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Mode:       $MODE"
echo "Branch:     $CURRENT_BRANCH"
echo "Prompt:     $PROMPT_FILE"
echo "Agents:     $FORGELOOP_AGENTS_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Task Routing: $TASK_ROUTING"
echo "  Planning: $PLANNING_MODEL ($CODEX_PLANNING_CONFIG)"
echo "  Review:   $REVIEW_MODEL ($CODEX_REVIEW_CONFIG)"
echo "  Security: $SECURITY_MODEL ($CODEX_SECURITY_CONFIG)"
echo "  Build:    $BUILD_MODEL (Claude $CLAUDE_MODEL)"
echo "Failover:   $ENABLE_FAILOVER"
echo "Autopush:   ${FORGELOOP_AUTOPUSH:-false}"
[ "$MAX_ITERATIONS" -gt 0 ] && echo "Max:        $MAX_ITERATIONS iterations"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

notify "🚀" "Forgeloop Started" "Mode: $MODE | Branch: $CURRENT_BRANCH"

if [ "$MODE" != "review" ] && [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: $PROMPT_FILE not found"
    exit 1
fi

# Session knowledge context (best-effort): write $RUNTIME_DIR/session-context.md and inject into prompts.
SESSION_CONTEXT_FILE=$(forgeloop_core__init_session_context "$REPO_DIR" "$FORGELOOP_DIR" "$RUNTIME_DIR")
if [[ -n "$SESSION_CONTEXT_FILE" ]]; then
    export FORGELOOP_SESSION_CONTEXT="$SESSION_CONTEXT_FILE"
fi

while true; do
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        echo "Reached max iterations: $MAX_ITERATIONS"
        break
    fi

    case "$MODE" in
        review)
            git diff 2>/dev/null | forgeloop_llm__exec "$REPO_DIR" "stdin" "review" "$STATE_FILE" "$LOG_FILE"
            ;;
        plan|plan-work)
            forgeloop_llm__exec "$REPO_DIR" "file:$PROMPT_FILE" "$MODE" "$STATE_FILE" "$LOG_FILE"
            ;;
        *)
            forgeloop_llm__exec "$REPO_DIR" "file:$PROMPT_FILE" "build" "$STATE_FILE" "$LOG_FILE"
            ;;
    esac

    if [ "$MODE" = "build" ]; then
        forgeloop_llm__run_codex_review "$REPO_DIR" "$REVIEW_SCHEMA" "$STATE_FILE" "$LOG_FILE"
    fi

    forgeloop_llm__security_gate "$REPO_DIR" "$SECURITY_SCHEMA" "$STATE_FILE" "$LOG_FILE"

    if [[ "$MODE" = "build" ]] && [[ -n "${FORGELOOP_VERIFY_CMD:-}" ]]; then
        if ! run_verify_cmd "$FORGELOOP_VERIFY_CMD"; then
            continue
        fi
    fi

    if [[ "$MODE" = "build" ]]; then
        if ! forgeloop_core__ci_gate "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"; then
            continue  # Agent should fix issues, loop continues
        fi
        forgeloop_core__git_push_branch "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"
    elif [[ "$MODE" = "plan" || "$MODE" = "plan-work" ]]; then
        if [[ "${FORGELOOP_PLAN_AUTOPUSH:-false}" == "true" ]]; then
            forgeloop_core__git_push_branch "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"
        fi
    fi

    ITERATION=$((ITERATION + 1))

    if [ $((ITERATION % 5)) -eq 0 ]; then
        notify "🔄" "Forgeloop Progress" "Completed $ITERATION iterations on $CURRENT_BRANCH (model: $AI_MODEL)"
    fi

    echo -e "\n\n======================== LOOP $ITERATION ($AI_MODEL) ========================\n"
done
