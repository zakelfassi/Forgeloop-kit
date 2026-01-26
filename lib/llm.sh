#!/usr/bin/env bash
# =============================================================================
# Ralph LLM Library
# =============================================================================
# LLM execution functions: model routing, rate limiting, ai_exec, review/security gates.
#
# Usage:
#   source "$REPO_DIR/ralph/lib/core.sh"  # Required dependency
#   source "$REPO_DIR/ralph/lib/llm.sh"
#
# This library is side-effect-free on source.
# All functions are namespaced with ralph_llm__ prefix.
# =============================================================================

# Prevent double-sourcing
[[ -n "${_RALPH_LLM_LOADED:-}" ]] && return 0
_RALPH_LLM_LOADED=1

# Ensure core.sh is loaded
if [[ -z "${_RALPH_CORE_LOADED:-}" ]]; then
    echo "Error: ralph/lib/core.sh must be sourced before ralph/lib/llm.sh" >&2
    exit 1
fi

# =============================================================================
# Model Configuration Defaults
# =============================================================================

# These can be overridden by exporting before sourcing or in config.sh
: "${PLANNING_MODEL:=codex}"
: "${REVIEW_MODEL:=codex}"
: "${SECURITY_MODEL:=codex}"
: "${BUILD_MODEL:=claude}"

: "${CLAUDE_CLI:=claude}"
: "${CLAUDE_MODEL:=opus}"
: "${CLAUDE_FLAGS:=--dangerously-skip-permissions --output-format=stream-json --verbose}"

: "${CODEX_CLI:=codex}"
: "${CODEX_FLAGS:=--dangerously-bypass-approvals-and-sandbox}"

: "${CODEX_PLANNING_CONFIG:=gpt-5.2:high}"
: "${CODEX_REVIEW_CONFIG:=gpt-5.2-codex:medium}"
: "${CODEX_SECURITY_CONFIG:=gpt-5.2-codex:medium}"

: "${ENABLE_FAILOVER:=true}"
: "${ENABLE_CODEX_REVIEW:=true}"
: "${TASK_ROUTING:=true}"

# Rate limit state (epoch timestamps when limit expires)
CLAUDE_RATE_LIMITED_UNTIL=${CLAUDE_RATE_LIMITED_UNTIL:-0}
CODEX_RATE_LIMITED_UNTIL=${CODEX_RATE_LIMITED_UNTIL:-0}

# Current model in use
AI_MODEL="${AI_MODEL:-$BUILD_MODEL}"

# =============================================================================
# State Persistence
# =============================================================================

# Load LLM state from a file
# Usage: ralph_llm__load_state "$STATE_FILE"
ralph_llm__load_state() {
    local state_file="$1"
    if [[ -f "$state_file" ]]; then
        # shellcheck disable=SC1090
        source "$state_file"
        if [[ -n "${FORCE_MODEL:-}" ]]; then
            AI_MODEL="$FORCE_MODEL"
        fi
    fi
}

# Save LLM state to a file
# Usage: ralph_llm__save_state "$STATE_FILE"
ralph_llm__save_state() {
    local state_file="$1"
    cat > "$state_file" << EOF
AI_MODEL=$AI_MODEL
CLAUDE_RATE_LIMITED_UNTIL=$CLAUDE_RATE_LIMITED_UNTIL
CODEX_RATE_LIMITED_UNTIL=$CODEX_RATE_LIMITED_UNTIL
EOF
}

# =============================================================================
# Model Detection
# =============================================================================

ralph_llm__has_claude() { command -v "$CLAUDE_CLI" &>/dev/null; }
ralph_llm__has_codex() { command -v "$CODEX_CLI" &>/dev/null; }

# =============================================================================
# Rate Limiting
# =============================================================================

# Check if a model is currently rate limited
# Usage: if ralph_llm__is_rate_limited "claude"; then ...
ralph_llm__is_rate_limited() {
    local model="$1"
    local now
    now=$(date +%s)

    case "$model" in
        claude) [[ "$CLAUDE_RATE_LIMITED_UNTIL" -gt "$now" ]] ;;
        codex) [[ "$CODEX_RATE_LIMITED_UNTIL" -gt "$now" ]] ;;
        *) return 1 ;;
    esac
}

# Parse rate limit duration from output file
# Usage: duration=$(ralph_llm__parse_rate_limit_duration "$output_file" "claude")
ralph_llm__parse_rate_limit_duration() {
    local output_file="$1"
    local model="$2"
    local default_sleep=$((60 * 60))

    local reset_time
    reset_time=$(grep -oE "resets [0-9]+[ap]m" "$output_file" 2>/dev/null | head -1 || echo "")

    if [[ -n "$reset_time" ]]; then
        local hour ampm
        hour=$(echo "$reset_time" | grep -oE "[0-9]+")
        ampm=$(echo "$reset_time" | grep -oE "[ap]m")

        if [[ "$ampm" = "pm" ]] && [[ "$hour" -ne 12 ]]; then
            hour=$((hour + 12))
        elif [[ "$ampm" = "am" ]] && [[ "$hour" -eq 12 ]]; then
            hour=0
        fi

        local now target
        now=$(TZ="America/Los_Angeles" date +%s)
        target=$(TZ="America/Los_Angeles" date -d "today ${hour}:00" +%s 2>/dev/null || \
                 TZ="America/Los_Angeles" date -j -f "%H:%M" "${hour}:00" +%s 2>/dev/null || echo "")

        if [[ -n "$target" ]]; then
            local diff=$((target - now))
            if [[ "$diff" -lt 0 ]]; then
                diff=$((diff + 86400))
            fi
            echo $((diff + 300))
            return
        fi
    fi

    case "$model" in
        claude) echo $((5 * 3600 + 300)) ;;
        codex) echo $((60 * 60)) ;;
        *) echo "$default_sleep" ;;
    esac
}

# =============================================================================
# Model Routing
# =============================================================================

# Get the preferred model for a task type
# Usage: model=$(ralph_llm__get_model_for_task "plan")
ralph_llm__get_model_for_task() {
    local task_type="${1:-build}"

    if [[ -n "${FORCE_MODEL:-}" ]]; then
        echo "$FORCE_MODEL"
        return 0
    fi

    if [[ "$TASK_ROUTING" = "true" ]]; then
        case "$task_type" in
            plan|plan-work) echo "$PLANNING_MODEL" ;;
            review) echo "$REVIEW_MODEL" ;;
            security) echo "$SECURITY_MODEL" ;;
            *) echo "$BUILD_MODEL" ;;
        esac
    else
        echo "claude"
    fi
}

# Get Codex configuration for a task type
# Usage: read -r model reasoning <<< "$(ralph_llm__get_codex_config_for_task "plan")"
ralph_llm__get_codex_config_for_task() {
    local task_type="${1:-build}"
    local config=""

    case "$task_type" in
        plan|plan-work) config="$CODEX_PLANNING_CONFIG" ;;
        review) config="$CODEX_REVIEW_CONFIG" ;;
        security) config="$CODEX_SECURITY_CONFIG" ;;
        *) config="$CODEX_PLANNING_CONFIG" ;;
    esac

    local model="${config%%:*}"
    local reasoning="${config##*:}"
    echo "$model $reasoning"
}

# =============================================================================
# LLM Execution
# =============================================================================

# Execute an LLM task with automatic failover and rate limit handling
# Usage: ralph_llm__exec "$REPO_DIR" "$prompt_source" "$task_type" "$STATE_FILE" "$LOG_FILE"
#   prompt_source: "file:PATH", "stdin", or literal prompt string
#   task_type: plan, plan-work, review, security, build (default)
ralph_llm__exec() {
    local repo_dir="$1"
    local prompt_source="$2"
    local task_type="${3:-build}"
    local state_file="${4:-}"
    local log_file="${5:-}"
    local work_scope="${WORK_SCOPE:-}"
    local mode="${MODE:-build}"

    local preferred_model
    preferred_model=$(ralph_llm__get_model_for_task "$task_type")
    local model="$preferred_model"
    local output_file
    output_file=$(mktemp)
    local exit_code=0
    local prompt_content=""

    # Check rate limiting and failover
    if ralph_llm__is_rate_limited "$model" && [[ "$ENABLE_FAILOVER" = "true" ]]; then
        local alt_model
        if [[ "$model" = "claude" ]]; then alt_model="codex"; else alt_model="claude"; fi
        if ! ralph_llm__is_rate_limited "$alt_model"; then
            ralph_core__log "Preferred model ($model) rate-limited for $task_type, using $alt_model" "$log_file"
            model="$alt_model"
        fi
    fi

    AI_MODEL="$model"

    # Resolve prompt content
    if [[ "$prompt_source" == file:* ]]; then
        local file_path="${prompt_source#file:}"
        if [[ "$mode" = "plan-work" ]] && [[ -n "$work_scope" ]]; then
            prompt_content=$(WORK_SCOPE="$work_scope" envsubst < "$file_path")
        else
            prompt_content=$(cat "$file_path")
        fi
    elif [[ "$prompt_source" = "stdin" ]]; then
        prompt_content=$(cat)
    else
        prompt_content="$prompt_source"
    fi

    # Prepend optional session context (persistent knowledge + experts)
    if [[ -n "${RALPH_SESSION_CONTEXT:-}" ]] && [[ -f "${RALPH_SESSION_CONTEXT:-}" ]]; then
        prompt_content="$(cat "$RALPH_SESSION_CONTEXT")"$'\n\n'"$prompt_content"
    fi

    ralph_core__log "Running task=$task_type with model=$model (preferred=$preferred_model)" "$log_file"

    case "$model" in
        claude)
            if ! ralph_llm__has_claude; then
                if ralph_llm__has_codex; then
                    ralph_core__log "Claude not available, forcing Codex..." "$log_file"
                    FORCE_MODEL="codex" ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file" <<< "$prompt_content"
                    return $?
                fi
                ralph_core__log "Neither Claude nor Codex is available" "$log_file"
                return 127
            fi

            echo "$prompt_content" | $CLAUDE_CLI -p \
                $CLAUDE_FLAGS \
                --model "$CLAUDE_MODEL" \
                2>&1 | tee "$output_file" || exit_code=$?

            if [[ "$exit_code" -ne 0 ]] && grep -qE "(\"error\":\{\"type\":\"rate_limit|anthropic.*rate.*limit|Usage limit reached|You.ve run out of|credit balance is too low)" "$output_file" 2>/dev/null; then
                ralph_core__log "Claude rate limited!" "$log_file"
                local sleep_duration
                sleep_duration=$(ralph_llm__parse_rate_limit_duration "$output_file" "claude")
                CLAUDE_RATE_LIMITED_UNTIL=$(($(date +%s) + sleep_duration))
                [[ -n "$state_file" ]] && ralph_llm__save_state "$state_file"

                if [[ "$ENABLE_FAILOVER" = "true" ]] && ralph_llm__has_codex && ! ralph_llm__is_rate_limited "codex"; then
                    ralph_core__log "Failing over to Codex..." "$log_file"
                    ralph_core__notify "$repo_dir" "🔄" "Model Failover" "Claude rate limited. Switching to Codex."
                    rm -f "$output_file"
                    FORCE_MODEL="codex" ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file" <<< "$prompt_content"
                    return $?
                fi

                local sleep_hours=$((sleep_duration / 3600))
                local sleep_mins=$(((sleep_duration % 3600) / 60))
                ralph_core__log "Sleeping ${sleep_hours}h ${sleep_mins}m..." "$log_file"
                ralph_core__notify "$repo_dir" "⏸️" "Ralph Paused" "Rate limited. Sleeping ${sleep_hours}h ${sleep_mins}m"
                rm -f "$output_file"
                sleep "$sleep_duration"
                CLAUDE_RATE_LIMITED_UNTIL=0
                [[ -n "$state_file" ]] && ralph_llm__save_state "$state_file"
                echo "$prompt_content" | ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file"
                return $?
            fi
            ;;

        codex)
            if ! ralph_llm__has_codex; then
                if ralph_llm__has_claude; then
                    ralph_core__log "Codex not available, forcing Claude..." "$log_file"
                    FORCE_MODEL="claude" ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file" <<< "$prompt_content"
                    return $?
                fi
                ralph_core__log "Neither Codex nor Claude is available" "$log_file"
                return 127
            fi

            local codex_config
            codex_config=$(ralph_llm__get_codex_config_for_task "$task_type")
            local codex_model="${codex_config%% *}"
            local codex_reasoning="${codex_config##* }"

            ralph_core__log "Codex config: model=$codex_model reasoning=$codex_reasoning" "$log_file"

            echo "$prompt_content" | $CODEX_CLI exec \
                $CODEX_FLAGS \
                -m "$codex_model" \
                -c "model_reasoning_effort=\"$codex_reasoning\"" \
                - 2>&1 | tee "$output_file" || exit_code=$?

            if [[ "$exit_code" -ne 0 ]] && grep -qE "(openai.*rate.*limit|Rate limit reached for|You exceeded your current quota|Request too large)" "$output_file" 2>/dev/null; then
                ralph_core__log "Codex rate limited!" "$log_file"
                local sleep_duration
                sleep_duration=$(ralph_llm__parse_rate_limit_duration "$output_file" "codex")
                CODEX_RATE_LIMITED_UNTIL=$(($(date +%s) + sleep_duration))
                [[ -n "$state_file" ]] && ralph_llm__save_state "$state_file"

                if [[ "$ENABLE_FAILOVER" = "true" ]] && ralph_llm__has_claude && ! ralph_llm__is_rate_limited "claude"; then
                    ralph_core__log "Failing over to Claude..." "$log_file"
                    ralph_core__notify "$repo_dir" "🔄" "Model Failover" "Codex rate limited. Switching to Claude."
                    rm -f "$output_file"
                    FORCE_MODEL="claude" ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file" <<< "$prompt_content"
                    return $?
                fi

                local sleep_hours=$((sleep_duration / 3600))
                local sleep_mins=$(((sleep_duration % 3600) / 60))
                ralph_core__log "Sleeping ${sleep_hours}h ${sleep_mins}m..." "$log_file"
                ralph_core__notify "$repo_dir" "⏸️" "Ralph Paused" "Rate limited. Sleeping ${sleep_hours}h ${sleep_mins}m"
                rm -f "$output_file"
                sleep "$sleep_duration"
                CODEX_RATE_LIMITED_UNTIL=0
                [[ -n "$state_file" ]] && ralph_llm__save_state "$state_file"
                echo "$prompt_content" | ralph_llm__exec "$repo_dir" "stdin" "$task_type" "$state_file" "$log_file"
                return $?
            fi
            ;;
    esac

    rm -f "$output_file"
    return $exit_code
}

# =============================================================================
# Review & Security Gates
# =============================================================================

# Run Codex review on recent changes
# Usage: ralph_llm__run_codex_review "$REPO_DIR" "$REVIEW_SCHEMA" "$STATE_FILE" "$LOG_FILE"
ralph_llm__run_codex_review() {
    local repo_dir="$1"
    local review_schema="$2"
    local state_file="${3:-}"
    local log_file="${4:-}"

    if ! ralph_llm__has_codex || [[ "$ENABLE_CODEX_REVIEW" != "true" ]]; then
        return 0
    fi
    if ralph_llm__is_rate_limited "codex"; then
        ralph_core__log "Skipping Codex review (rate limited)" "$log_file"
        return 0
    fi

    local diff
    diff=$(git diff HEAD~1 2>/dev/null || echo "")
    if [[ -z "$diff" ]]; then
        ralph_core__log "No changes to review" "$log_file"
        return 0
    fi

    ralph_core__log "Running Codex review..." "$log_file"

    local review_result
    review_result=$(mktemp)

    local codex_config
    codex_config=$(ralph_llm__get_codex_config_for_task "review")
    local codex_model="${codex_config%% *}"
    local codex_reasoning="${codex_config##* }"

    {
        printf "Review this diff for bugs, security issues, edge cases, and code quality. Be thorough but concise.\n"
        printf "Return JSON matching the provided schema.\n\nDIFF:\n"
        printf '%s\n' "$diff"
    } | $CODEX_CLI exec --sandbox read-only \
        -m "$codex_model" \
        -c "model_reasoning_effort=\"$codex_reasoning\"" \
        --output-schema "$review_schema" \
        -o "$review_result" \
        - 2>&1 || true

    if [[ -f "$review_result" ]] && [[ -s "$review_result" ]]; then
        local verdict finding_count
        verdict=$(jq -r '.verdict // "unknown"' "$review_result" 2>/dev/null || echo "unknown")
        finding_count=$(jq -r '.findings | length' "$review_result" 2>/dev/null || echo "0")

        ralph_core__log "Codex review: $verdict ($finding_count findings)" "$log_file"

        if [[ "$verdict" = "needs_fixes" ]] && [[ "$finding_count" -gt 0 ]]; then
            local fixes
            fixes=$(jq -r '.findings[] | select(.severity == "high" or .severity == "critical") | "- [\(.severity)] \(.title): \(.fix // .description)"' "$review_result" 2>/dev/null || echo "")

            if [[ -n "$fixes" ]]; then
                ralph_core__log "Feeding Codex findings back for repair..." "$log_file"
                printf "Fix these issues found in code review:\n\n%s" "$fixes" | ralph_llm__exec "$repo_dir" "stdin" "build" "$state_file" "$log_file"

                if [[ -n "${RALPH_TEST_CMD:-}" ]]; then
                    ralph_core__log "Running tests after review fixes: $RALPH_TEST_CMD" "$log_file"
                    (cd "$repo_dir" && bash -lc "$RALPH_TEST_CMD" 2>&1 | tail -50) || true
                fi
            fi
        fi
    fi

    rm -f "$review_result"
}

# Run security review on staged/recent changes
# Usage: ralph_llm__security_gate "$REPO_DIR" "$SECURITY_SCHEMA" "$STATE_FILE" "$LOG_FILE"
ralph_llm__security_gate() {
    local repo_dir="$1"
    local security_schema="$2"
    local state_file="${3:-}"
    local log_file="${4:-}"

    local diff
    diff=$(git diff --staged 2>/dev/null || echo "")
    if [[ -z "$diff" ]]; then
        diff=$(git diff HEAD~1 2>/dev/null || echo "")
    fi
    [[ -z "$diff" ]] && return 0

    ralph_core__log "Running security review..." "$log_file"

    local security_result
    security_result=$(mktemp)

    local sec_model
    sec_model=$(ralph_llm__get_model_for_task "security")

    if ralph_llm__is_rate_limited "$sec_model"; then
        local alt_model
        if [[ "$sec_model" = "claude" ]]; then alt_model="codex"; else alt_model="claude"; fi
        if ! ralph_llm__is_rate_limited "$alt_model"; then
            sec_model="$alt_model"
        else
            ralph_core__log "Both models rate-limited, skipping security review" "$log_file"
            return 0
        fi
    fi

    case "$sec_model" in
        codex)
            local codex_config
            codex_config=$(ralph_llm__get_codex_config_for_task "security")
            local codex_model="${codex_config%% *}"
            local codex_reasoning="${codex_config##* }"

            {
                printf "You are a security engineer. Review this diff for vulnerabilities: injection, XSS, auth bypass, secrets exposure, path traversal.\n"
                printf "Output JSON matching the provided schema.\n\nDIFF:\n"
                printf '%s\n' "$diff"
            } | $CODEX_CLI exec --sandbox read-only \
                -m "$codex_model" \
                -c "model_reasoning_effort=\"$codex_reasoning\"" \
                --output-schema "$security_schema" \
                -o "$security_result" \
                - 2>&1 || true
            ;;
        claude)
            echo "$diff" | $CLAUDE_CLI -p --output-format json \
                --model "$CLAUDE_MODEL" \
                --append-system-prompt "You are a security engineer. Review for vulnerabilities including: injection, XSS, auth bypass, secrets exposure, path traversal." \
                --json-schema "$(cat "$security_schema")" \
                "Review this diff for security vulnerabilities." 2>/dev/null \
            | jq -r '.structured_output // .' > "$security_result" || true
            ;;
    esac

    if [[ -f "$security_result" ]] && [[ -s "$security_result" ]]; then
        local safe
        safe=$(jq -r '.safe // true' "$security_result" 2>/dev/null || echo "true")
        if [[ "$safe" = "false" ]]; then
            ralph_core__log "Security review found issues" "$log_file"
            jq -r '.issues[] | "  - [\(.severity)] \(.type): \(.description)"' "$security_result" 2>/dev/null || true
            ralph_core__notify "$repo_dir" "🚨" "Security Review Warning" "Found potential security issues in diff"
        fi
    fi

    rm -f "$security_result"
}
