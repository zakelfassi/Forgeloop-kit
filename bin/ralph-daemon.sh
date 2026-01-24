#!/bin/bash
set -euo pipefail

# =============================================================================
# Ralph Daemon (Portable, Hardened)
# =============================================================================
# Periodically runs Ralph planning/build based on REQUESTS.md and IMPLEMENTATION_PLAN.md.
#
# HARDENED: Detects repeated blockers and pauses instead of looping endlessly.
#
# Usage: ./ralph/bin/ralph-daemon.sh [interval_seconds]
# Default interval: 300 (5 minutes)
#
# Triggers (in REQUESTS.md):
#   [PAUSE]   - pause daemon loop
#   [REPLAN]  - run planning once, then continue
#   [DEPLOY]  - run deploy command (RALPH_DEPLOY_CMD), if configured
#   [INGEST_LOGS] - analyze configured logs and append a request (RALPH_INGEST_LOGS_CMD or RALPH_INGEST_LOGS_FILE)
# =============================================================================

INTERVAL=${1:-300}

# Resolve repo directory and load libraries
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RALPH_DIR="$REPO_DIR/ralph"
if [[ ! -f "$RALPH_DIR/lib/core.sh" ]]; then
    RALPH_DIR="$REPO_DIR"
fi
source "$RALPH_DIR/config.sh" 2>/dev/null || true
source "$RALPH_DIR/lib/core.sh"

# Setup runtime directories and paths
RUNTIME_DIR=$(ralph_core__ensure_runtime_dirs "$REPO_DIR")
LOG_FILE="${RALPH_DAEMON_LOG_FILE:-$RUNTIME_DIR/logs/daemon.log}"
LOCK_FILE="${RALPH_DAEMON_LOCK_FILE:-$RUNTIME_DIR/daemon.lock}"
STATE_FILE="$RUNTIME_DIR/daemon.state"

REQUESTS_FILE="${RALPH_REQUESTS_FILE:-REQUESTS.md}"
PLAN_FILE="${RALPH_IMPLEMENTATION_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
QUESTIONS_FILE="${RALPH_QUESTIONS_FILE:-QUESTIONS.md}"

# Blocker detection settings
MAX_BLOCKED_ITERATIONS="${RALPH_MAX_BLOCKED_ITERATIONS:-3}"
BLOCKER_PAUSE_SECONDS="${RALPH_BLOCKER_PAUSE_SECONDS:-1800}"  # 30 minutes
BLOCKED_ITERATION_COUNT=0
LAST_BLOCKER_HASH=""

# Convenience wrappers
log() { ralph_core__log "$1" "$LOG_FILE"; }
notify() { ralph_core__notify "$REPO_DIR" "$@"; }

# =============================================================================
# State Persistence
# =============================================================================

save_state() {
    cat > "$STATE_FILE" << EOF
BLOCKED_ITERATION_COUNT=$BLOCKED_ITERATION_COUNT
LAST_BLOCKER_HASH=$LAST_BLOCKER_HASH
EOF
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        log "Loaded state: blocked_count=$BLOCKED_ITERATION_COUNT"
    fi
}

# =============================================================================
# Blocker Detection (HARDENED)
# =============================================================================

# Get hash of unanswered questions to detect repeated blockers
get_blocker_hash() {
    local questions_path="$REPO_DIR/$QUESTIONS_FILE"
    if [ -f "$questions_path" ]; then
        # Hash the unanswered question IDs without blocking on stdin
        local blocker_ids
        blocker_ids=$(grep -E '^## Q-[0-9]+' "$questions_path" 2>/dev/null | \
            while read -r line; do
                local qid
                qid=$(echo "$line" | grep -oE 'Q-[0-9]+')
                # Check if this question is still awaiting response
                if grep -A5 "$qid" "$questions_path" 2>/dev/null | grep -q "⏳ Awaiting response"; then
                    echo "$qid"
                fi
            done | sort)

        if [[ -z "$blocker_ids" ]]; then
            echo "none"
        else
            ralph_core__hash "$blocker_ids"
        fi
    else
        echo "none"
    fi
}

# Check if we're stuck on the same blocker
check_blocker_loop() {
    local current_hash
    current_hash=$(get_blocker_hash)

    if [ "$current_hash" = "none" ] || [ -z "$current_hash" ]; then
        # No blockers, reset counter
        BLOCKED_ITERATION_COUNT=0
        LAST_BLOCKER_HASH=""
        save_state
        return 1  # Not blocked
    fi

    if [ "$current_hash" = "$LAST_BLOCKER_HASH" ]; then
        # Same blocker as before
        BLOCKED_ITERATION_COUNT=$((BLOCKED_ITERATION_COUNT + 1))
        log "Repeated blocker detected (count: $BLOCKED_ITERATION_COUNT/$MAX_BLOCKED_ITERATIONS)"

        if [ "$BLOCKED_ITERATION_COUNT" -ge "$MAX_BLOCKED_ITERATIONS" ]; then
            save_state
            return 0  # Blocked, should pause
        fi
    else
        # New blocker, start tracking
        BLOCKED_ITERATION_COUNT=1
        LAST_BLOCKER_HASH="$current_hash"
        log "New blocker detected, tracking..."
    fi

    save_state
    return 1  # Not yet at threshold
}

# Pause when stuck on same blocker
pause_for_blocker() {
    local pause_mins=$((BLOCKER_PAUSE_SECONDS / 60))
    log "Stuck on same blocker for $BLOCKED_ITERATION_COUNT iterations. Pausing for ${pause_mins}m..."
    notify "⏸️" "Ralph Paused - Awaiting Input" \
        "Stuck on same blocker for $BLOCKED_ITERATION_COUNT iterations. Pausing for ${pause_mins}m. Check QUESTIONS.md for unanswered questions."

    sleep "$BLOCKER_PAUSE_SECONDS"

    # Reset counter after pause to give it another try
    BLOCKED_ITERATION_COUNT=0
    save_state
    log "Resuming after blocker pause..."
}

is_paused() {
    ralph_core__has_flag "$REPO_DIR" "$REQUESTS_FILE" "PAUSE"
}

has_pending_tasks() {
    [ -f "$REPO_DIR/$PLAN_FILE" ] && grep -q '^- \[ \]' "$REPO_DIR/$PLAN_FILE" 2>/dev/null
}

run_plan() {
    log "Running planning..."
    notify "📋" "Ralph Planning" "Starting plan"
    (cd "$REPO_DIR" && "$REPO_DIR/ralph/bin/loop.sh" plan 1) || true
}

run_build() {
    local iters="${1:-10}"
    log "Running build ($iters iterations)..."
    notify "🔨" "Ralph Build" "Starting build ($iters iterations)"
    (cd "$REPO_DIR" && "$REPO_DIR/ralph/bin/loop.sh" "$iters") || true
}

run_deploy() {
    if [ -z "${RALPH_DEPLOY_CMD:-}" ]; then
        log "DEPLOY requested but RALPH_DEPLOY_CMD not set; skipping"
        notify "⚠️" "Ralph Deploy" "DEPLOY requested but no deploy command configured"
        return 0
    fi

    log "Running deploy: $RALPH_DEPLOY_CMD"
    notify "🚀" "Ralph Deploy" "Running deploy"
    (cd "$REPO_DIR" && bash -lc "$RALPH_DEPLOY_CMD") || true

    if [[ "${RALPH_POST_DEPLOY_INGEST_LOGS:-false}" == "true" ]]; then
        local wait_seconds="${RALPH_POST_DEPLOY_OBSERVE_SECONDS:-0}"
        if [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [[ "$wait_seconds" -gt 0 ]]; then
            log "Post-deploy observe: waiting ${wait_seconds}s before ingesting logs..."
            sleep "$wait_seconds"
        fi
        run_ingest_logs || true
    fi
}

run_ingest_logs() {
    local ingest_script="$REPO_DIR/ralph/bin/ingest-logs.sh"
    if [[ ! -x "$ingest_script" ]]; then
        log "INGEST_LOGS requested but ingest-logs.sh not found/executable; skipping"
        notify "⚠️" "Ralph Log Ingest" "INGEST_LOGS requested but ingest-logs.sh not available"
        return 0
    fi

    if [[ -z "${RALPH_INGEST_LOGS_CMD:-}" ]] && [[ -z "${RALPH_INGEST_LOGS_FILE:-}" ]]; then
        log "INGEST_LOGS requested but RALPH_INGEST_LOGS_CMD / RALPH_INGEST_LOGS_FILE not set; skipping"
        notify "⚠️" "Ralph Log Ingest" "INGEST_LOGS requested but no log source configured"
        return 0
    fi

    local args=(--requests "$REQUESTS_FILE")
    if [[ -n "${RALPH_INGEST_LOGS_CMD:-}" ]]; then
        args+=(--cmd "$RALPH_INGEST_LOGS_CMD" --source "daemon")
    else
        args+=(--file "$RALPH_INGEST_LOGS_FILE" --source "daemon")
    fi

    if [[ -n "${RALPH_INGEST_LOGS_TAIL:-}" ]]; then
        args+=(--tail "$RALPH_INGEST_LOGS_TAIL")
    fi

    log "Running log ingest..."
    notify "📥" "Ralph Log Ingest" "Analyzing logs into REQUESTS"
    (cd "$REPO_DIR" && "$ingest_script" "${args[@]}") || true
}

main_loop() {
    load_state
    log "Ralph daemon starting (interval: ${INTERVAL}s)"
    log "Blocker detection: max $MAX_BLOCKED_ITERATIONS consecutive blocked iterations before ${BLOCKER_PAUSE_SECONDS}s pause"

    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "Another daemon instance is running. Exiting."
        exit 0
    fi

    notify "🤖" "Ralph Daemon Started" "Interval: ${INTERVAL}s"

    while true; do
        if is_paused; then
            log "Paused ([PAUSE] in $REQUESTS_FILE). Sleeping..."
            sleep "$INTERVAL"
            continue
        fi

        # Check for blocker loop before running tasks
        if check_blocker_loop; then
            pause_for_blocker
            continue
        fi

        if ralph_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "REPLAN"; then
            run_plan
        fi

        if ralph_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "DEPLOY"; then
            run_deploy
        fi

        if ralph_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "INGEST_LOGS"; then
            run_ingest_logs
        fi

        if [ ! -f "$REPO_DIR/$PLAN_FILE" ]; then
            run_plan
        fi

        if has_pending_tasks; then
            run_build 10
        else
            log "No pending tasks. Sleeping..."
        fi

        sleep "$INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'log "Shutting down..."; exit 0' SIGINT SIGTERM
    main_loop
fi
