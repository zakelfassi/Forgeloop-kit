#!/bin/bash
set -euo pipefail

# =============================================================================
# Forgeloop Loop (Portable)
# =============================================================================
# Runs an agent loop using Claude and/or Codex CLIs with task-based routing.
#
# Usage:
#   ./forgeloop/bin/loop.sh [plan] [max_iterations]
#   ./forgeloop/bin/loop.sh plan-work "work description" [max_iterations]
#   ./forgeloop/bin/loop.sh review
#   ./forgeloop/bin/loop.sh [max_iterations]
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
MAX_ITERATIONS=0

if [ "${1:-}" = "plan" ]; then
    MODE="plan"
    PROMPT_FILE="$PROMPT_PLAN"
    MAX_ITERATIONS=${2:-0}
elif [ "${1:-}" = "plan-work" ]; then
    if [ -z "${2:-}" ]; then
        echo "Error: plan-work requires a work description"
        echo "Usage: ./forgeloop/bin/loop.sh plan-work \"description\" [max_iterations]"
        exit 1
    fi
    MODE="plan-work"
    WORK_DESCRIPTION="$2"
    PROMPT_FILE="$PROMPT_PLAN_WORK"
    MAX_ITERATIONS=${3:-5}
elif [ "${1:-}" = "review" ]; then
    MODE="review"
    MAX_ITERATIONS=1
elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=$1
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
SESSION_CONTEXT_FILE="$RUNTIME_DIR/session-context.md"
if [[ -x "$FORGELOOP_DIR/bin/session-start.sh" ]] && ([[ -d "$REPO_DIR/system/knowledge" ]] || [[ -d "$REPO_DIR/system/experts" ]]); then
    FORGELOOP_SESSION_QUIET=true FORGELOOP_SESSION_NO_STDOUT=true "$FORGELOOP_DIR/bin/session-start.sh" >/dev/null 2>&1 || true
    if [[ -f "$SESSION_CONTEXT_FILE" ]]; then
        export FORGELOOP_SESSION_CONTEXT="$SESSION_CONTEXT_FILE"
    fi
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

    if ! forgeloop_core__ci_gate "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"; then
        continue  # Agent should fix issues, loop continues
    fi
    forgeloop_core__git_push_branch "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"

    ITERATION=$((ITERATION + 1))

    if [ $((ITERATION % 5)) -eq 0 ]; then
        notify "🔄" "Forgeloop Progress" "Completed $ITERATION iterations on $CURRENT_BRANCH (model: $AI_MODEL)"
    fi

    echo -e "\n\n======================== LOOP $ITERATION ($AI_MODEL) ========================\n"
done
