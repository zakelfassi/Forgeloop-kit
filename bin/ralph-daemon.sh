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
# =============================================================================

INTERVAL=${1:-300}
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_DIR/ralph/config.sh" 2>/dev/null || true

RUNTIME_DIR="${RALPH_RUNTIME_DIR:-.ralph}"
if [[ "$RUNTIME_DIR" != /* ]]; then
    RUNTIME_DIR="$REPO_DIR/$RUNTIME_DIR"
fi
mkdir -p "$RUNTIME_DIR/logs"

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

notify() {
    if [ -x "$REPO_DIR/ralph/bin/notify.sh" ]; then
        "$REPO_DIR/ralph/bin/notify.sh" "$@" 2>/dev/null || true
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

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
        # Hash the unanswered question IDs
        grep -E '^## Q-[0-9]+' "$questions_path" 2>/dev/null | \
            while read -r line; do
                local qid
                qid=$(echo "$line" | grep -oE 'Q-[0-9]+')
                # Check if this question is still awaiting response
                if grep -A5 "$qid" "$questions_path" 2>/dev/null | grep -q "⏳ Awaiting response"; then
                    echo "$qid"
                fi
            done | sort | md5sum 2>/dev/null | cut -d' ' -f1 || shasum 2>/dev/null | cut -d' ' -f1 || echo "none"
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
    grep -q '\\[PAUSE\\]' "$REPO_DIR/$REQUESTS_FILE" 2>/dev/null
}

consume_flag() {
    local flag="$1"
    local file="$REPO_DIR/$REQUESTS_FILE"
    grep -q "\\[$flag\\]" "$file" 2>/dev/null || return 1
    # GNU/BSD compatible in-place edit
    sed -i.bak "s/\\[$flag\\]//g" "$file" && rm -f "$file.bak"
    git add "$REQUESTS_FILE" 2>/dev/null || true
    git commit -m "ralph: processed $flag" --allow-empty 2>/dev/null || true
    return 0
}

has_pending_tasks() {
    [ -f "$REPO_DIR/$PLAN_FILE" ] && grep -q '^\\- \\[ \\]' "$REPO_DIR/$PLAN_FILE" 2>/dev/null
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

        if consume_flag "REPLAN"; then
            run_plan
        fi

        if consume_flag "DEPLOY"; then
            run_deploy
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

trap 'log "Shutting down..."; exit 0' SIGINT SIGTERM
main_loop

