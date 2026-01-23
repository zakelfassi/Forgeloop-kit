#!/bin/bash
set -euo pipefail

# =============================================================================
# Ralph Tasks Loop
# =============================================================================
# Runs an agent loop using structured prd.json tasks instead of IMPLEMENTATION_PLAN.md.
# This is an alternative to loop.sh for teams preferring machine-readable task tracking.
#
# Usage:
#   ./ralph/bin/loop-tasks.sh [max_iterations]
#   ./ralph/bin/loop-tasks.sh --prd path/to/prd.json [max_iterations]
#
# Config:
#   RALPH_TASKS_PRD_FILE - Path to prd.json (default: prd.json)
#   RALPH_TASKS_PROGRESS_FILE - Path to progress.txt (default: progress.txt)
#   RALPH_PROMPT_TASKS - Prompt template (default: PROMPT_tasks.md)
# =============================================================================

# Resolve repo directory and load libraries
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RALPH_DIR="$REPO_DIR/ralph"
if [[ ! -f "$RALPH_DIR/lib/core.sh" ]]; then
    RALPH_DIR="$REPO_DIR"
fi
source "$RALPH_DIR/config.sh" 2>/dev/null || true
source "$RALPH_DIR/lib/core.sh"
source "$RALPH_DIR/lib/llm.sh"

# Setup runtime directories and paths
RUNTIME_DIR=$(ralph_core__ensure_runtime_dirs "$REPO_DIR")
LOG_FILE="${RALPH_TASKS_LOG_FILE:-$RUNTIME_DIR/logs/tasks.log}"
STATE_FILE="$RUNTIME_DIR/tasks.state"
LAST_BRANCH_FILE="$RUNTIME_DIR/.tasks-last-branch"

# Task file defaults
PRD_FILE="${RALPH_TASKS_PRD_FILE:-prd.json}"
PROGRESS_FILE="${RALPH_TASKS_PROGRESS_FILE:-progress.txt}"
PROMPT_FILE="${RALPH_PROMPT_TASKS:-PROMPT_tasks.md}"

REVIEW_SCHEMA="${RALPH_REVIEW_SCHEMA:-$REPO_DIR/ralph/schemas/review.schema.json}"
SECURITY_SCHEMA="${RALPH_SECURITY_SCHEMA:-$REPO_DIR/ralph/schemas/security.schema.json}"

# Convenience wrappers
log() { ralph_core__log "$1" "$LOG_FILE"; }
notify() { ralph_core__notify "$REPO_DIR" "$@"; }

# =============================================================================
# Argument Parsing
# =============================================================================

MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prd)
            PRD_FILE="$2"
            shift 2
            ;;
        --progress)
            PROGRESS_FILE="$2"
            shift 2
            ;;
        --prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                MAX_ITERATIONS=$1
            fi
            shift
            ;;
    esac
done

# Resolve relative paths
[[ "$PRD_FILE" != /* ]] && PRD_FILE="$REPO_DIR/$PRD_FILE"
[[ "$PROGRESS_FILE" != /* ]] && PROGRESS_FILE="$REPO_DIR/$PROGRESS_FILE"
[[ "$PROMPT_FILE" != /* ]] && PROMPT_FILE="$REPO_DIR/$PROMPT_FILE"

# =============================================================================
# Task Helpers
# =============================================================================

# Get tasks array from prd.json (supports both "tasks" and "userStories" keys)
get_tasks_key() {
    local prd_path="$1"
    if jq -e '.tasks' "$prd_path" >/dev/null 2>&1; then
        echo "tasks"
    elif jq -e '.userStories' "$prd_path" >/dev/null 2>&1; then
        echo "userStories"
    else
        echo ""
    fi
}

# Get the next incomplete task (lowest priority number where passes=false)
get_next_task() {
    local prd_path="$1"
    local tasks_key
    tasks_key=$(get_tasks_key "$prd_path")

    if [[ -z "$tasks_key" ]]; then
        echo ""
        return
    fi

    jq -r ".$tasks_key | map(select(.passes == false)) | sort_by(.priority) | .[0] // empty" "$prd_path"
}

get_next_task_id() {
    local prd_path="$1"
    local tasks_key
    tasks_key=$(get_tasks_key "$prd_path")

    if [[ -z "$tasks_key" ]]; then
        echo ""
        return
    fi

    jq -r ".$tasks_key | map(select(.passes == false)) | sort_by(.priority) | .[0].id // empty" "$prd_path"
}

# Check if all tasks are complete
all_tasks_complete() {
    local prd_path="$1"
    local tasks_key
    tasks_key=$(get_tasks_key "$prd_path")

    if [[ -z "$tasks_key" ]]; then
        return 0  # No tasks = complete
    fi

    local incomplete
    incomplete=$(jq -r ".$tasks_key | map(select(.passes == false)) | length" "$prd_path")
    [[ "$incomplete" -eq 0 ]]
}

# Get branch name from prd.json
get_prd_branch() {
    local prd_path="$1"
    jq -r '.branchName // empty' "$prd_path" 2>/dev/null || echo ""
}

# =============================================================================
# Branch Management
# =============================================================================

ensure_on_branch() {
    local target_branch="$1"

    if [[ -z "$target_branch" ]]; then
        return 0
    fi

    local current_branch
    current_branch=$(ralph_core__git_current_branch)

    if [[ "$current_branch" != "$target_branch" ]]; then
        log "Switching to branch: $target_branch"

        # Check if branch exists
        if git show-ref --verify --quiet "refs/heads/$target_branch" 2>/dev/null; then
            git checkout "$target_branch"
        else
            log "Creating new branch: $target_branch"
            git checkout -b "$target_branch"
        fi
    fi
}

# =============================================================================
# Archive Management
# =============================================================================

archive_if_branch_changed() {
    local prd_path="$1"
    local progress_path="$2"

    if [[ ! -f "$prd_path" ]] || [[ ! -f "$LAST_BRANCH_FILE" ]]; then
        return 0
    fi

    local current_branch last_branch
    current_branch=$(get_prd_branch "$prd_path")
    last_branch=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

    if [[ -n "$current_branch" ]] && [[ -n "$last_branch" ]] && [[ "$current_branch" != "$last_branch" ]]; then
        local archive_dir="$RUNTIME_DIR/archive"
        local date_str folder_name archive_folder
        date_str=$(date +%Y-%m-%d)
        folder_name=$(echo "$last_branch" | sed 's|^[^/]*/||')
        archive_folder="$archive_dir/$date_str-$folder_name"

        log "Archiving previous run: $last_branch"
        mkdir -p "$archive_folder"

        [[ -f "$prd_path" ]] && cp "$prd_path" "$archive_folder/"
        [[ -f "$progress_path" ]] && cp "$progress_path" "$archive_folder/"

        log "Archived to: $archive_folder"

        # Reset progress file
        cat > "$progress_path" << EOF
# Ralph Tasks Progress Log
Started: $(date)
Branch: $current_branch
---

## Codebase Patterns
<!-- Agent: Add discovered patterns here -->

---

## Progress
EOF
    fi

    # Track current branch
    if [[ -n "$current_branch" ]]; then
        echo "$current_branch" > "$LAST_BRANCH_FILE"
    fi
}

# =============================================================================
# Progress File Management
# =============================================================================

init_progress_file() {
    local progress_path="$1"
    local prd_path="$2"

    if [[ ! -f "$progress_path" ]]; then
        local branch_name
        branch_name=$(get_prd_branch "$prd_path")

        cat > "$progress_path" << EOF
# Ralph Tasks Progress Log
Started: $(date)
Branch: ${branch_name:-unknown}
---

## Codebase Patterns
<!-- Agent: Add discovered patterns here -->

---

## Progress
EOF
    fi
}

# =============================================================================
# Main Loop
# =============================================================================

main() {
    cd "$REPO_DIR"

    # Validate prd.json exists
    if [[ ! -f "$PRD_FILE" ]]; then
        echo "Error: PRD file not found: $PRD_FILE"
        echo "Create a prd.json file or use --prd to specify the path."
        exit 1
    fi

    # Validate prompt file exists
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "Error: Prompt file not found: $PROMPT_FILE"
        echo "Create PROMPT_tasks.md or use --prompt to specify the path."
        exit 1
    fi

    # Archive if branch changed
    archive_if_branch_changed "$PRD_FILE" "$PROGRESS_FILE"

    # Initialize progress file
    init_progress_file "$PROGRESS_FILE" "$PRD_FILE"

    # Ensure on correct branch
    local prd_branch
    prd_branch=$(get_prd_branch "$PRD_FILE")
    ensure_on_branch "$prd_branch"

    local current_branch
    current_branch=$(ralph_core__git_current_branch)

    # Load LLM state
    ralph_llm__load_state "$STATE_FILE"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Mode:       tasks"
    echo "Branch:     $current_branch"
    echo "PRD:        $PRD_FILE"
    echo "Progress:   $PROGRESS_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Max:        $MAX_ITERATIONS iterations"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    notify "🚀" "Ralph Tasks Started" "Branch: $current_branch"

    local iteration=0
    while [[ "$iteration" -lt "$MAX_ITERATIONS" ]]; do
        # Check if all tasks are complete
        if all_tasks_complete "$PRD_FILE"; then
            log "All tasks complete!"
            notify "✅" "Ralph Tasks Complete" "All tasks in prd.json are done!"
            echo ""
            echo "✅ All tasks complete!"
            exit 0
        fi

        # Get next task
        local next_task_id
        next_task_id=$(get_next_task_id "$PRD_FILE")

        if [[ -z "$next_task_id" ]]; then
            log "No pending tasks found"
            break
        fi

        log "Working on task: $next_task_id"

        echo ""
        echo "==============================================================="
        echo "  Iteration $((iteration + 1)) of $MAX_ITERATIONS"
        echo "  Task: $next_task_id"
        echo "==============================================================="

        # Run the agent with the tasks prompt
        ralph_llm__exec "$REPO_DIR" "file:$PROMPT_FILE" "build" "$STATE_FILE" "$LOG_FILE"

        # Run optional review
        if [[ "${ENABLE_CODEX_REVIEW:-true}" == "true" ]]; then
            ralph_llm__run_codex_review "$REPO_DIR" "$REVIEW_SCHEMA" "$STATE_FILE" "$LOG_FILE"
        fi

        # Security gate
        ralph_llm__security_gate "$REPO_DIR" "$SECURITY_SCHEMA" "$STATE_FILE" "$LOG_FILE"

        # Push if enabled
        ralph_core__git_push_branch "$REPO_DIR" "$current_branch" "$LOG_FILE"

        iteration=$((iteration + 1))

        if [[ $((iteration % 3)) -eq 0 ]]; then
            notify "🔄" "Ralph Tasks Progress" "Completed $iteration iterations on $current_branch"
        fi

        echo -e "\n\n======================== LOOP $iteration ($AI_MODEL) ========================\n"

        sleep 2
    done

    echo ""
    echo "Reached max iterations ($MAX_ITERATIONS)."
    echo "Check $PROGRESS_FILE for status."
    exit 1
}

main
