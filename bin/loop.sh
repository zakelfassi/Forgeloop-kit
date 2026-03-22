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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"
REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true
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

print_intake_readiness_guidance() {
    local prompt_source kickoff_cmd
    prompt_source="$(forgeloop_core__resolve_intake_prompt_source "$REPO_DIR" "$FORGELOOP_DIR" || true)"

    if [[ -x "$REPO_DIR/forgeloop.sh" ]]; then
        kickoff_cmd="./forgeloop.sh kickoff \"<one paragraph project brief>\""
    else
        kickoff_cmd="./forgeloop/bin/kickoff.sh \"<one paragraph project brief>\""
    fi

    echo "Checklist intake is not ready yet." >&2
    echo "This repo still looks like a fresh Forgeloop bootstrap with template-only specs/docs/plan files." >&2
    if [[ -n "$prompt_source" ]]; then
        echo "Review the intake prompt at: $prompt_source" >&2
    else
        echo "Could not find PROMPT_intake.md. Reinstall or upgrade Forgeloop so the intake prompt is available." >&2
    fi
    echo "Then render a shareable kickoff prompt with:" >&2
    echo "  $kickoff_cmd" >&2
    echo "That writes: docs/KICKOFF_PROMPT.md" >&2
    echo "Before retrying checklist plan/build, apply real repo-local intake output:" >&2
    echo "  - docs/*" >&2
    echo "  - specs/*" >&2
    echo "  - IMPLEMENTATION_PLAN.md" >&2
    echo "Checklist lane remains the default. Tasks/workflow lanes stay explicit opt-ins." >&2
}

run_verify_cmd() {
    local cmd="$1"
    if [[ -z "$cmd" ]]; then
        return 0
    fi

    local verify_dir="$RUNTIME_DIR/verify"
    mkdir -p "$verify_dir"
    local verify_out="$verify_dir/verify-last.txt"
    FORGELOOP_LAST_VERIFY_OUTPUT_FILE="$verify_out"
    export FORGELOOP_LAST_VERIFY_OUTPUT_FILE

    local validation_msg=""
    if ! validation_msg=$(forgeloop_core__validate_verify_cmd "$cmd"); then
        printf "%s\n" "$validation_msg" > "$verify_out"
        local untrusted_file="$verify_dir/verify-last.untrusted.md"
        local max_chars="${FORGELOOP_UNTRUSTED_CONTEXT_MAX_CHARS:-20000}"
        forgeloop_core__wrap_untrusted_context "Verify Command Failure Output" "$verify_out" "$untrusted_file" "$max_chars" || true
        forgeloop_core__append_extra_context_file "$untrusted_file"
        log "Verify command rejected as deploy-like"
        return 1
    fi

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
CURRENT_BRANCH="${FORGELOOP_RUNTIME_BRANCH:-$(forgeloop_core__git_current_branch)}"

if [ "$MODE" = "plan-work" ]; then
    if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
        echo "Error: plan-work should be run on a work branch, not main/master"
        exit 1
    fi
    export WORK_SCOPE="$WORK_DESCRIPTION"
fi

export MODE
export FORGELOOP_RUNTIME_SURFACE="loop"
export FORGELOOP_RUNTIME_MODE="$MODE"
export FORGELOOP_RUNTIME_BRANCH="$CURRENT_BRANCH"

PROMPT_FILE_PATH="$PROMPT_FILE"
if [[ "$PROMPT_FILE_PATH" != /* ]]; then
    PROMPT_FILE_PATH="$REPO_DIR/$PROMPT_FILE_PATH"
fi

if [[ "$MODE" != "review" ]] && [[ ! -f "$PROMPT_FILE_PATH" ]]; then
    echo "Error: $PROMPT_FILE not found" >&2
    exit 1
fi

if [[ "$MODE" == "plan" || "$MODE" == "build" ]]; then
    if ! forgeloop_core__check_checklist_intake_readiness "$REPO_DIR" "$FORGELOOP_DIR"; then
        print_intake_readiness_guidance
        exit 2
    fi
fi

ACTIVE_RUNTIME_CLAIM_ID=""
cleanup_active_runtime_claim() {
    forgeloop_core__active_runtime_claim_end "$REPO_DIR" "${ACTIVE_RUNTIME_CLAIM_ID:-}" || true
}

if ! ACTIVE_RUNTIME_CLAIM_ID=$(forgeloop_core__active_runtime_claim_begin "$REPO_DIR" "bash" "loop" "$MODE" "$CURRENT_BRANCH"); then
    echo "Error: another active runtime owner is holding this repo" >&2
    exit 1
fi
export FORGELOOP_ACTIVE_RUNTIME_CLAIM_ID="$ACTIVE_RUNTIME_CLAIM_ID"
trap cleanup_active_runtime_claim EXIT

cd "$REPO_DIR"
forgeloop_llm__load_state "$STATE_FILE"
forgeloop_core__write_runtime_state "$REPO_DIR" "starting" "loop" "Initializing $MODE loop" \
    "mode=$MODE" "branch=$CURRENT_BRANCH" "max_iterations=$MAX_ITERATIONS"

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

# Session knowledge context (best-effort): write $RUNTIME_DIR/session-context.md and inject into prompts.
SESSION_CONTEXT_FILE=$(forgeloop_core__init_session_context "$REPO_DIR" "$FORGELOOP_DIR" "$RUNTIME_DIR")
if [[ -n "$SESSION_CONTEXT_FILE" ]]; then
    export FORGELOOP_SESSION_CONTEXT="$SESSION_CONTEXT_FILE"
fi

while true; do
    if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
        forgeloop_core__write_runtime_state "$REPO_DIR" "complete" "loop" "Reached max iterations for $MODE loop" \
            "mode=$MODE" "branch=$CURRENT_BRANCH" "iterations=$ITERATION"
        echo "Reached max iterations: $MAX_ITERATIONS"
        break
    fi

    loop_status="building"
    if [[ "$MODE" = "plan" || "$MODE" = "plan-work" ]]; then
        loop_status="planning"
    elif [[ "$MODE" = "review" ]]; then
        loop_status="reviewing"
    fi
    forgeloop_core__write_runtime_state "$REPO_DIR" "$loop_status" "loop" "Running $MODE iteration" \
        "mode=$MODE" "branch=$CURRENT_BRANCH" "iteration=$ITERATION"

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
        if ! forgeloop_llm__run_codex_review "$REPO_DIR" "$REVIEW_SCHEMA" "$STATE_FILE" "$LOG_FILE"; then
            log "Review oscillation escalated; exiting loop"
            exit 1
        fi
    fi

    forgeloop_llm__security_gate "$REPO_DIR" "$SECURITY_SCHEMA" "$STATE_FILE" "$LOG_FILE"

    if [[ "$MODE" = "build" ]] && [[ -n "${FORGELOOP_VERIFY_CMD:-}" ]]; then
        if ! run_verify_cmd "$FORGELOOP_VERIFY_CMD"; then
            if forgeloop_core__handle_repeated_failure "$REPO_DIR" "verify" "Verify command failed: $FORGELOOP_VERIFY_CMD" "${FORGELOOP_LAST_VERIFY_OUTPUT_FILE:-}" "$LOG_FILE"; then
                exit 1
            fi
            continue
        fi
    fi

    if [[ "$MODE" = "build" ]]; then
        if ! forgeloop_core__ci_gate "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"; then
            if forgeloop_core__handle_repeated_failure "$REPO_DIR" "ci" "CI gate failed on branch $CURRENT_BRANCH" "${FORGELOOP_LAST_CI_OUTPUT_FILE:-}" "$LOG_FILE"; then
                exit 1
            fi
            continue  # Agent should fix issues, loop continues
        fi
        if ! forgeloop_core__git_push_branch "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"; then
            if forgeloop_core__handle_repeated_failure "$REPO_DIR" "push" "Push failed for branch $CURRENT_BRANCH" "" "$LOG_FILE" "review"; then
                exit 1
            fi
            continue
        fi
    elif [[ "$MODE" = "plan" || "$MODE" = "plan-work" ]]; then
        if [[ "${FORGELOOP_PLAN_AUTOPUSH:-false}" == "true" ]]; then
            if ! forgeloop_core__git_push_branch "$REPO_DIR" "$CURRENT_BRANCH" "$LOG_FILE"; then
                if forgeloop_core__handle_repeated_failure "$REPO_DIR" "push" "Plan push failed for branch $CURRENT_BRANCH" "" "$LOG_FILE" "review"; then
                    exit 1
                fi
                continue
            fi
        fi
    fi

    forgeloop_core__clear_failure_state "$REPO_DIR"
    forgeloop_core__write_runtime_state "$REPO_DIR" "healthy" "loop" "Completed $MODE iteration" \
        "mode=$MODE" "branch=$CURRENT_BRANCH" "iteration=$((ITERATION + 1))"

    ITERATION=$((ITERATION + 1))

    if [ $((ITERATION % 5)) -eq 0 ]; then
        notify "🔄" "Forgeloop Progress" "Completed $ITERATION iterations on $CURRENT_BRANCH (model: $AI_MODEL)"
    fi

    echo -e "\n\n======================== LOOP $ITERATION ($AI_MODEL) ========================\n"
done

if [[ "$ITERATION" -eq 0 ]]; then
    forgeloop_core__write_runtime_state "$REPO_DIR" "idle" "loop" "Loop exited without running an iteration" \
        "mode=$MODE" "branch=$CURRENT_BRANCH"
fi
