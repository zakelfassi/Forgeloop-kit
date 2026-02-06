#!/bin/bash
set -euo pipefail

# =============================================================================
# Forgeloop Daemon (Portable, Hardened)
# =============================================================================
# Periodically runs Forgeloop planning/build based on REQUESTS.md and IMPLEMENTATION_PLAN.md.
#
# HARDENED: Detects repeated blockers and pauses instead of looping endlessly.
#
# Usage: ./forgeloop/bin/forgeloop-daemon.sh [interval_seconds]
# Default interval: 300 (5 minutes)
#
# Triggers (in REQUESTS.md):
#   [PAUSE]   - pause daemon loop
#   [REPLAN]  - run planning once, then continue
#   [DEPLOY]  - run deploy command (FORGELOOP_DEPLOY_CMD), if configured
#   [INGEST_LOGS] - analyze configured logs and append a request (FORGELOOP_INGEST_LOGS_CMD or FORGELOOP_INGEST_LOGS_FILE)
# =============================================================================

INTERVAL=${1:-300}

# Resolve repo directory and load libraries
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FORGELOOP_DIR="$REPO_DIR/forgeloop"
if [[ ! -f "$FORGELOOP_DIR/lib/core.sh" ]]; then
    FORGELOOP_DIR="$REPO_DIR"
fi
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true
source "$FORGELOOP_DIR/lib/core.sh"

# Setup runtime directories and paths
RUNTIME_DIR=$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")
LOG_FILE="${FORGELOOP_DAEMON_LOG_FILE:-$RUNTIME_DIR/logs/daemon.log}"
LOCK_FILE="${FORGELOOP_DAEMON_LOCK_FILE:-$RUNTIME_DIR/daemon.lock}"
STATE_FILE="$RUNTIME_DIR/daemon.state"

REQUESTS_FILE="${FORGELOOP_REQUESTS_FILE:-REQUESTS.md}"
PLAN_FILE="${FORGELOOP_IMPLEMENTATION_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
QUESTIONS_FILE="${FORGELOOP_QUESTIONS_FILE:-QUESTIONS.md}"

# Blocker detection settings
MAX_BLOCKED_ITERATIONS="${FORGELOOP_MAX_BLOCKED_ITERATIONS:-3}"
BLOCKER_PAUSE_SECONDS="${FORGELOOP_BLOCKER_PAUSE_SECONDS:-1800}"  # 30 minutes
BLOCKED_ITERATION_COUNT=0
LAST_BLOCKER_HASH=""

# Loop timeouts (avoid a single stuck build holding the daemon lock forever)
# - FORGELOOP_LOOP_TIMEOUT_SECONDS applies to build runs
# - FORGELOOP_PLAN_TIMEOUT_SECONDS applies to planning runs
FORGELOOP_LOOP_TIMEOUT_SECONDS="${FORGELOOP_LOOP_TIMEOUT_SECONDS:-3600}"   # 60 minutes
FORGELOOP_PLAN_TIMEOUT_SECONDS="${FORGELOOP_PLAN_TIMEOUT_SECONDS:-900}"    # 15 minutes

# Convenience wrappers
log() { forgeloop_core__log "$1" "$LOG_FILE"; }
notify() { forgeloop_core__notify "$REPO_DIR" "$@"; }

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
        blocker_ids=$(awk '
            /^## Q-[0-9]+/ { qid=$2; awaiting=0; next }
            /^## / { if (qid != "" && awaiting==1) print qid; qid=""; awaiting=0; next }
            /⏳ Awaiting response/ { if (qid != "") awaiting=1 }
            END { if (qid != "" && awaiting==1) print qid }
        ' "$questions_path" 2>/dev/null | sort)

        if [[ -z "$blocker_ids" ]]; then
            echo "none"
        else
            forgeloop_core__hash "$blocker_ids"
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
    notify "⏸️" "Forgeloop Paused - Awaiting Input" \
        "Stuck on same blocker for $BLOCKED_ITERATION_COUNT iterations. Pausing for ${pause_mins}m. Check QUESTIONS.md for unanswered questions."

    sleep "$BLOCKER_PAUSE_SECONDS"

    # Reset counter after pause to give it another try
    BLOCKED_ITERATION_COUNT=0
    save_state
    log "Resuming after blocker pause..."
}

is_paused() {
    forgeloop_core__has_flag "$REPO_DIR" "$REQUESTS_FILE" "PAUSE"
}

has_pending_tasks() {
    [ -f "$REPO_DIR/$PLAN_FILE" ] && grep -q '^- \[ \]' "$REPO_DIR/$PLAN_FILE" 2>/dev/null
}

run_with_timeout() {
    local seconds="$1"; shift
    local label="$1"; shift

    if command -v timeout >/dev/null 2>&1; then
        # TERM first, then KILL after 30s grace
        timeout --signal=TERM --kill-after=30s "${seconds}s" "$@"
        return $?
    fi

    log "Warning: 'timeout' not available; running without timeout ($label)"
    "$@"
}

run_plan() {
    log "Running planning..."
    notify "📋" "Forgeloop Planning" "Starting plan"

    local rc=0
    (cd "$REPO_DIR" && run_with_timeout "$FORGELOOP_PLAN_TIMEOUT_SECONDS" "plan" "$REPO_DIR/forgeloop/bin/loop.sh" plan 1) || rc=$?

    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
        log "Planning timed out after ${FORGELOOP_PLAN_TIMEOUT_SECONDS}s (rc=$rc)"
        notify "⏱️" "Forgeloop Planning Timed Out" "Planning exceeded ${FORGELOOP_PLAN_TIMEOUT_SECONDS}s. Will retry next cycle."
    fi

    return 0
}

run_build() {
    local iters="${1:-10}"
    log "Running build ($iters iterations)..."
    notify "🔨" "Forgeloop Build" "Starting build ($iters iterations)"

    local rc=0
    (cd "$REPO_DIR" && run_with_timeout "$FORGELOOP_LOOP_TIMEOUT_SECONDS" "build" "$REPO_DIR/forgeloop/bin/loop.sh" "$iters") || rc=$?

    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
        log "Build timed out after ${FORGELOOP_LOOP_TIMEOUT_SECONDS}s (rc=$rc)"
        notify "⏱️" "Forgeloop Build Timed Out" "Build exceeded ${FORGELOOP_LOOP_TIMEOUT_SECONDS}s. Will retry next cycle."
    fi

    return 0
}

run_deploy() {
    if [ -z "${FORGELOOP_DEPLOY_CMD:-}" ]; then
        log "DEPLOY requested but FORGELOOP_DEPLOY_CMD not set; skipping"
        notify "⚠️" "Forgeloop Deploy" "DEPLOY requested but no deploy command configured"
        return 0
    fi

    log "Running deploy: $FORGELOOP_DEPLOY_CMD"
    notify "🚀" "Forgeloop Deploy" "Running deploy"
    (cd "$REPO_DIR" && bash -lc "$FORGELOOP_DEPLOY_CMD") || true

    if [[ "${FORGELOOP_POST_DEPLOY_INGEST_LOGS:-false}" == "true" ]]; then
        local wait_seconds="${FORGELOOP_POST_DEPLOY_OBSERVE_SECONDS:-0}"
        if [[ "$wait_seconds" =~ ^[0-9]+$ ]] && [[ "$wait_seconds" -gt 0 ]]; then
            log "Post-deploy observe: waiting ${wait_seconds}s before ingesting logs..."
            sleep "$wait_seconds"
        fi
        run_ingest_logs || true
    fi
}

run_ingest_logs() {
    local ingest_script="$REPO_DIR/forgeloop/bin/ingest-logs.sh"
    if [[ ! -x "$ingest_script" ]]; then
        log "INGEST_LOGS requested but ingest-logs.sh not found/executable; skipping"
        notify "⚠️" "Forgeloop Log Ingest" "INGEST_LOGS requested but ingest-logs.sh not available"
        return 0
    fi

    if [[ -z "${FORGELOOP_INGEST_LOGS_CMD:-}" ]] && [[ -z "${FORGELOOP_INGEST_LOGS_FILE:-}" ]]; then
        log "INGEST_LOGS requested but FORGELOOP_INGEST_LOGS_CMD / FORGELOOP_INGEST_LOGS_FILE not set; skipping"
        notify "⚠️" "Forgeloop Log Ingest" "INGEST_LOGS requested but no log source configured"
        return 0
    fi

    local args=(--requests "$REQUESTS_FILE")
    if [[ -n "${FORGELOOP_INGEST_LOGS_CMD:-}" ]]; then
        args+=(--cmd "$FORGELOOP_INGEST_LOGS_CMD" --source "daemon")
    else
        args+=(--file "$FORGELOOP_INGEST_LOGS_FILE" --source "daemon")
    fi

    if [[ -n "${FORGELOOP_INGEST_LOGS_TAIL:-}" ]]; then
        args+=(--tail "$FORGELOOP_INGEST_LOGS_TAIL")
    fi

    log "Running log ingest..."
    notify "📥" "Forgeloop Log Ingest" "Analyzing logs into REQUESTS"
    (cd "$REPO_DIR" && "$ingest_script" "${args[@]}") || true
}

main_loop() {
    load_state
    log "Forgeloop daemon starting (interval: ${INTERVAL}s)"
    log "Blocker detection: max $MAX_BLOCKED_ITERATIONS consecutive blocked iterations before ${BLOCKER_PAUSE_SECONDS}s pause"

    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log "Another daemon instance is running. Exiting."
        exit 0
    fi

    notify "🤖" "Forgeloop Daemon Started" "Interval: ${INTERVAL}s"

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

        if forgeloop_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "REPLAN"; then
            run_plan
        fi

        if forgeloop_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "DEPLOY"; then
            run_deploy
        fi

        if forgeloop_core__consume_flag "$REPO_DIR" "$REQUESTS_FILE" "INGEST_LOGS"; then
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
