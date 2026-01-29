#!/usr/bin/env bash
# =============================================================================
# Forgeloop Flag Library
# =============================================================================
# Flag parsing, evaluation, and capture handling for goal-directed build loops.
#
# A Flag is the smallest shippable unit with clear acceptance criteria.
# The loop runs until the Flag is captured (all criteria pass).
#
# Usage:
#   source "$REPO_DIR/forgeloop/lib/core.sh"  # Required dependency
#   source "$REPO_DIR/forgeloop/lib/flag.sh"
#
# This library is side-effect-free on source.
# All functions are namespaced with forgeloop_flag__ prefix.
# =============================================================================

# Prevent double-sourcing
[[ -n "${_FORGELOOP_FLAG_LOADED:-}" ]] && return 0
_FORGELOOP_FLAG_LOADED=1

# Ensure core.sh is loaded
if [[ -z "${_FORGELOOP_CORE_LOADED:-}" ]]; then
    echo "Error: forgeloop/lib/core.sh must be sourced before forgeloop/lib/flag.sh" >&2
    exit 1
fi

# =============================================================================
# Flag State (populated by forgeloop_flag__load)
# =============================================================================

FLAG_LOADED=0
FLAG_NAME=""
FLAG_GOAL=""
FLAG_VERSION=""
FLAG_MAX_ITERATIONS=10
FLAG_BLOCKER_THRESHOLD=3

# Arrays for acceptance criteria
declare -a FLAG_CI_COMMANDS=()
declare -a FLAG_TEST_PATTERNS=()
FLAG_SMOKE_SCRIPT=""

# On-capture settings
FLAG_ON_CAPTURE_NOTIFY=true
FLAG_ON_CAPTURE_TAG=""
FLAG_ON_CAPTURE_COMMIT_MSG=""
FLAG_NEXT_FLAG=""

# Non-goals and edge cases (for agent context)
declare -a FLAG_NON_GOALS=()
declare -a FLAG_EDGE_CASES=()

# =============================================================================
# Flag Parsing
# =============================================================================

# Load and parse a FLAG.md file
# Usage: forgeloop_flag__load "$REPO_DIR" ["$FLAG_FILE"]
forgeloop_flag__load() {
    local repo_dir="$1"
    local flag_file="${2:-FLAG.md}"
    local full_path="$repo_dir/$flag_file"

    # Reset state
    FLAG_LOADED=0
    FLAG_NAME=""
    FLAG_GOAL=""
    FLAG_CI_COMMANDS=()
    FLAG_TEST_PATTERNS=()
    FLAG_SMOKE_SCRIPT=""

    if [[ ! -f "$full_path" ]]; then
        return 1
    fi

    # Parse simple key: "value" patterns
    FLAG_NAME=$(grep -E '^name:' "$full_path" | head -1 | sed 's/^name: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
    FLAG_GOAL=$(grep -E '^goal:' "$full_path" | head -1 | sed 's/^goal: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
    FLAG_VERSION=$(grep -E '^version:' "$full_path" | head -1 | sed 's/^version: *//' | xargs)
    
    # Parse max_iterations
    local max_iter
    max_iter=$(grep -E '^max_iterations:' "$full_path" | head -1 | sed 's/^max_iterations: *//' | xargs)
    [[ -n "$max_iter" ]] && FLAG_MAX_ITERATIONS="$max_iter"

    # Parse blocker_threshold
    local blocker_thresh
    blocker_thresh=$(grep -E '^blocker_threshold:' "$full_path" | head -1 | sed 's/^blocker_threshold: *//' | xargs)
    [[ -n "$blocker_thresh" ]] && FLAG_BLOCKER_THRESHOLD="$blocker_thresh"

    # Parse acceptance.ci array (lines starting with "- " under "ci:")
    local in_ci=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*ci: ]]; then
            in_ci=1
            continue
        fi
        if [[ $in_ci -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                local cmd
                cmd=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
                [[ -n "$cmd" ]] && FLAG_CI_COMMANDS+=("$cmd")
            elif [[ "$line" =~ ^[[:space:]]*[a-z]+: ]] || [[ -z "$line" ]]; then
                in_ci=0
            fi
        fi
    done < "$full_path"

    # Parse acceptance.tests array
    local in_tests=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*tests: ]]; then
            in_tests=1
            continue
        fi
        if [[ $in_tests -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                local pattern
                pattern=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
                [[ -n "$pattern" ]] && FLAG_TEST_PATTERNS+=("$pattern")
            elif [[ "$line" =~ ^[[:space:]]*[a-z]+: ]] || [[ -z "$line" ]]; then
                in_tests=0
            fi
        fi
    done < "$full_path"

    # Parse smoke script
    FLAG_SMOKE_SCRIPT=$(grep -E '^[[:space:]]*smoke:' "$full_path" | head -1 | sed 's/^[[:space:]]*smoke: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)

    # Parse on_capture settings
    FLAG_ON_CAPTURE_TAG=$(grep -E '^[[:space:]]*tag:' "$full_path" | head -1 | sed 's/^[[:space:]]*tag: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
    FLAG_ON_CAPTURE_COMMIT_MSG=$(grep -E '^[[:space:]]*commit_message:' "$full_path" | head -1 | sed 's/^[[:space:]]*commit_message: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
    FLAG_NEXT_FLAG=$(grep -E '^[[:space:]]*next_flag:' "$full_path" | head -1 | sed 's/^[[:space:]]*next_flag: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)

    # Parse notify (defaults to true)
    local notify_val
    notify_val=$(grep -E '^[[:space:]]*notify:' "$full_path" | head -1 | sed 's/^[[:space:]]*notify: *//' | xargs)
    if [[ "$notify_val" == "false" ]]; then
        FLAG_ON_CAPTURE_NOTIFY=false
    else
        FLAG_ON_CAPTURE_NOTIFY=true
    fi

    # Parse non_goals array
    local in_non_goals=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^non_goals: ]]; then
            in_non_goals=1
            continue
        fi
        if [[ $in_non_goals -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                local item
                item=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
                [[ -n "$item" ]] && FLAG_NON_GOALS+=("$item")
            elif [[ "$line" =~ ^[a-z_]+: ]] || [[ -z "$line" ]]; then
                in_non_goals=0
            fi
        fi
    done < "$full_path"

    # Parse edge_cases array
    local in_edge_cases=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^edge_cases: ]]; then
            in_edge_cases=1
            continue
        fi
        if [[ $in_edge_cases -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]* ]]; then
                local item
                item=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | xargs)
                [[ -n "$item" ]] && FLAG_EDGE_CASES+=("$item")
            elif [[ "$line" =~ ^[a-z_]+: ]] || [[ -z "$line" ]]; then
                in_edge_cases=0
            fi
        fi
    done < "$full_path"

    FLAG_LOADED=1
    return 0
}

# Check if a flag is currently loaded
# Usage: if forgeloop_flag__is_loaded; then ...
forgeloop_flag__is_loaded() {
    [[ "$FLAG_LOADED" -eq 1 ]] && [[ -n "$FLAG_NAME" ]]
}

# Print flag summary (for logging)
# Usage: forgeloop_flag__summary
forgeloop_flag__summary() {
    if ! forgeloop_flag__is_loaded; then
        echo "No flag loaded"
        return 1
    fi

    echo "Flag: $FLAG_NAME"
    echo "Goal: $FLAG_GOAL"
    echo "CI commands: ${#FLAG_CI_COMMANDS[@]}"
    echo "Test patterns: ${#FLAG_TEST_PATTERNS[@]}"
    [[ -n "$FLAG_SMOKE_SCRIPT" ]] && echo "Smoke: $FLAG_SMOKE_SCRIPT"
    echo "Max iterations: $FLAG_MAX_ITERATIONS"
}

# =============================================================================
# Acceptance Checks
# =============================================================================

# Run CI acceptance commands
# Usage: forgeloop_flag__check_ci "$REPO_DIR" "$LOG_FILE"
# Returns 0 if all pass, 1 if any fail
forgeloop_flag__check_ci() {
    local repo_dir="$1"
    local log_file="${2:-}"

    if [[ ${#FLAG_CI_COMMANDS[@]} -eq 0 ]]; then
        return 0  # No CI commands, vacuously true
    fi

    local cmd
    for cmd in "${FLAG_CI_COMMANDS[@]}"; do
        forgeloop_core__log "Flag CI check: $cmd" "$log_file"
        if ! (cd "$repo_dir" && bash -lc "$cmd" >/dev/null 2>&1); then
            forgeloop_core__log "Flag CI check FAILED: $cmd" "$log_file"
            return 1
        fi
        forgeloop_core__log "Flag CI check PASSED: $cmd" "$log_file"
    done

    return 0
}

# Check for test patterns in output
# Usage: forgeloop_flag__check_tests "$TEST_OUTPUT_FILE" "$LOG_FILE"
# Returns 0 if all patterns found, 1 if any missing
forgeloop_flag__check_tests() {
    local test_output="$1"
    local log_file="${2:-}"

    if [[ ${#FLAG_TEST_PATTERNS[@]} -eq 0 ]]; then
        return 0  # No test patterns, vacuously true
    fi

    if [[ ! -f "$test_output" ]]; then
        forgeloop_core__log "Flag test check: no test output file" "$log_file"
        return 1
    fi

    local pattern
    for pattern in "${FLAG_TEST_PATTERNS[@]}"; do
        if ! grep -q "$pattern" "$test_output" 2>/dev/null; then
            forgeloop_core__log "Flag test pattern NOT FOUND: $pattern" "$log_file"
            return 1
        fi
        forgeloop_core__log "Flag test pattern found: $pattern" "$log_file"
    done

    return 0
}

# Run smoke test script
# Usage: forgeloop_flag__check_smoke "$REPO_DIR" "$LOG_FILE"
# Returns 0 if passes (or no smoke test), 1 if fails
forgeloop_flag__check_smoke() {
    local repo_dir="$1"
    local log_file="${2:-}"

    if [[ -z "$FLAG_SMOKE_SCRIPT" ]]; then
        return 0  # No smoke test, vacuously true
    fi

    local smoke_path="$repo_dir/$FLAG_SMOKE_SCRIPT"
    if [[ ! -x "$smoke_path" ]]; then
        forgeloop_core__log "Flag smoke script not executable: $FLAG_SMOKE_SCRIPT" "$log_file"
        return 1
    fi

    forgeloop_core__log "Running flag smoke test: $FLAG_SMOKE_SCRIPT" "$log_file"
    if (cd "$repo_dir" && "$smoke_path" >/dev/null 2>&1); then
        forgeloop_core__log "Flag smoke test PASSED" "$log_file"
        return 0
    else
        forgeloop_core__log "Flag smoke test FAILED" "$log_file"
        return 1
    fi
}

# Check if flag is captured (all acceptance criteria pass)
# Usage: forgeloop_flag__is_captured "$REPO_DIR" "$TEST_OUTPUT_FILE" "$LOG_FILE"
# Returns 0 if captured, 1 if not
forgeloop_flag__is_captured() {
    local repo_dir="$1"
    local test_output="${2:-}"
    local log_file="${3:-}"

    if ! forgeloop_flag__is_loaded; then
        return 1  # No flag loaded, can't be captured
    fi

    forgeloop_core__log "Checking flag capture: $FLAG_NAME" "$log_file"

    # All checks must pass
    if ! forgeloop_flag__check_ci "$repo_dir" "$log_file"; then
        forgeloop_core__log "Flag not captured: CI checks failed" "$log_file"
        return 1
    fi

    if ! forgeloop_flag__check_tests "$test_output" "$log_file"; then
        forgeloop_core__log "Flag not captured: test patterns not found" "$log_file"
        return 1
    fi

    if ! forgeloop_flag__check_smoke "$repo_dir" "$log_file"; then
        forgeloop_core__log "Flag not captured: smoke test failed" "$log_file"
        return 1
    fi

    forgeloop_core__log "🏁 FLAG CAPTURED: $FLAG_NAME" "$log_file"
    return 0
}

# =============================================================================
# Capture Actions
# =============================================================================

# Commit with flag capture message
# Usage: forgeloop_flag__commit "$REPO_DIR" "$LOG_FILE"
forgeloop_flag__commit() {
    local repo_dir="$1"
    local log_file="${2:-}"

    local msg="${FLAG_ON_CAPTURE_COMMIT_MSG:-🏁 FLAG: $FLAG_NAME}"

    if ! forgeloop_core__is_git_worktree_clean; then
        git -C "$repo_dir" add -A
        git -C "$repo_dir" commit -m "$msg" || true
        forgeloop_core__log "Committed flag capture: $msg" "$log_file"
    fi
}

# Tag the flag capture
# Usage: forgeloop_flag__tag "$REPO_DIR" "$LOG_FILE"
forgeloop_flag__tag() {
    local repo_dir="$1"
    local log_file="${2:-}"

    if [[ -z "$FLAG_ON_CAPTURE_TAG" ]]; then
        return 0  # No tag configured
    fi

    git -C "$repo_dir" tag -a "$FLAG_ON_CAPTURE_TAG" -m "Flag captured: $FLAG_NAME" 2>/dev/null || true
    forgeloop_core__log "Tagged: $FLAG_ON_CAPTURE_TAG" "$log_file"

    # Push tag if autopush enabled
    if [[ "${FORGELOOP_AUTOPUSH:-false}" == "true" ]]; then
        local remote="${FORGELOOP_GIT_REMOTE:-origin}"
        git -C "$repo_dir" push "$remote" "$FLAG_ON_CAPTURE_TAG" 2>/dev/null || true
    fi
}

# Archive captured flag
# Usage: forgeloop_flag__archive "$REPO_DIR" "$FLAG_FILE" "$LOG_FILE"
forgeloop_flag__archive() {
    local repo_dir="$1"
    local flag_file="${2:-FLAG.md}"
    local log_file="${3:-}"

    local archive_dir="$repo_dir/flags/captured"
    mkdir -p "$archive_dir"

    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local archive_name="${FLAG_NAME:-flag}-${timestamp}.md"

    if [[ -f "$repo_dir/$flag_file" ]]; then
        mv "$repo_dir/$flag_file" "$archive_dir/$archive_name"
        forgeloop_core__log "Archived flag to: flags/captured/$archive_name" "$log_file"
    fi
}

# Chain to next flag
# Usage: forgeloop_flag__chain "$REPO_DIR" "$LOG_FILE"
# Returns 0 if chained to next flag, 1 if no next flag
forgeloop_flag__chain() {
    local repo_dir="$1"
    local log_file="${2:-}"

    if [[ -z "$FLAG_NEXT_FLAG" ]]; then
        return 1  # No next flag
    fi

    if [[ ! -f "$repo_dir/$FLAG_NEXT_FLAG" ]]; then
        forgeloop_core__log "Next flag not found: $FLAG_NEXT_FLAG" "$log_file"
        return 1
    fi

    forgeloop_core__log "Chaining to next flag: $FLAG_NEXT_FLAG" "$log_file"
    cp "$repo_dir/$FLAG_NEXT_FLAG" "$repo_dir/FLAG.md"

    # Reload the new flag
    forgeloop_flag__load "$repo_dir"
    return 0
}

# Full capture sequence: commit, tag, notify, archive, chain
# Usage: forgeloop_flag__on_capture "$REPO_DIR" "$LOG_FILE"
# Returns 0 if should continue (chained), 1 if should halt
forgeloop_flag__on_capture() {
    local repo_dir="$1"
    local log_file="${2:-}"

    local captured_flag_name="$FLAG_NAME"

    # Commit
    forgeloop_flag__commit "$repo_dir" "$log_file"

    # Tag
    forgeloop_flag__tag "$repo_dir" "$log_file"

    # Notify
    if [[ "$FLAG_ON_CAPTURE_NOTIFY" == "true" ]]; then
        forgeloop_core__notify "$repo_dir" "🏁" "Flag Captured" "$captured_flag_name is complete!"
    fi

    # Archive
    forgeloop_flag__archive "$repo_dir" "FLAG.md" "$log_file"

    # Chain to next flag
    if forgeloop_flag__chain "$repo_dir" "$log_file"; then
        forgeloop_core__log "Continuing with next flag: $FLAG_NAME" "$log_file"
        return 0  # Continue loop with new flag
    fi

    forgeloop_core__log "No next flag. Loop complete." "$log_file"
    return 1  # Halt loop
}

# =============================================================================
# Agent Context Generation
# =============================================================================

# Generate context string for LLM prompts
# Usage: context=$(forgeloop_flag__agent_context)
forgeloop_flag__agent_context() {
    if ! forgeloop_flag__is_loaded; then
        return 0
    fi

    echo "## Current Flag: $FLAG_NAME"
    echo ""
    echo "**Goal:** $FLAG_GOAL"
    echo ""

    if [[ ${#FLAG_NON_GOALS[@]} -gt 0 ]]; then
        echo "**Non-goals (out of scope):**"
        for item in "${FLAG_NON_GOALS[@]}"; do
            echo "- $item"
        done
        echo ""
    fi

    if [[ ${#FLAG_EDGE_CASES[@]} -gt 0 ]]; then
        echo "**Edge cases to handle:**"
        for item in "${FLAG_EDGE_CASES[@]}"; do
            echo "- $item"
        done
        echo ""
    fi

    echo "**Acceptance criteria:**"
    if [[ ${#FLAG_CI_COMMANDS[@]} -gt 0 ]]; then
        echo "- CI: ${FLAG_CI_COMMANDS[*]}"
    fi
    if [[ ${#FLAG_TEST_PATTERNS[@]} -gt 0 ]]; then
        echo "- Tests must include: ${FLAG_TEST_PATTERNS[*]}"
    fi
    if [[ -n "$FLAG_SMOKE_SCRIPT" ]]; then
        echo "- Smoke test: $FLAG_SMOKE_SCRIPT"
    fi
}
