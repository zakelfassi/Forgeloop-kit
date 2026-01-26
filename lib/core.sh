#!/usr/bin/env bash
# =============================================================================
# Ralph Core Library
# =============================================================================
# Shared utilities for Ralph scripts: logging, notifications, config loading,
# runtime dir management, git helpers, and flag consumption.
#
# Usage: source "$REPO_DIR/ralph/lib/core.sh"
#
# This library is side-effect-free on source (no implicit cd, no file writes).
# All functions are namespaced with ralph_core__ prefix to avoid collisions.
# =============================================================================

# Prevent double-sourcing
[[ -n "${_RALPH_CORE_LOADED:-}" ]] && return 0
_RALPH_CORE_LOADED=1

# =============================================================================
# Path Resolution
# =============================================================================

# Resolve the repository directory from a script location
# Usage: REPO_DIR=$(ralph_core__resolve_repo_dir "$0")
ralph_core__resolve_repo_dir() {
    local script_path="${1:-$0}"
    local script_dir
    script_dir="$(cd "$(dirname "$script_path")" && pwd)"

    # Assume scripts are in ralph/bin/ or ralph/lib/
    if [[ "$script_dir" == */ralph/bin ]] || [[ "$script_dir" == */ralph/lib ]]; then
        echo "$(cd "$script_dir/../.." && pwd)"
    elif [[ "$script_dir" == */bin ]] || [[ "$script_dir" == */lib ]]; then
        echo "$(cd "$script_dir/.." && pwd)"
    else
        # Fallback: walk up looking for ralph/config.sh
        local dir="$script_dir"
        while [[ "$dir" != "/" ]]; do
            if [[ -f "$dir/ralph/config.sh" ]]; then
                echo "$dir"
                return 0
            fi
            dir="$(dirname "$dir")"
        done
        # Last resort: current directory
        pwd
    fi
}

# Load Ralph configuration from config.sh
# Usage: ralph_core__load_config "$REPO_DIR"
ralph_core__load_config() {
    local repo_dir="$1"
    # shellcheck disable=SC1091
    source "$repo_dir/ralph/config.sh" 2>/dev/null || true
}

# Ensure runtime directories exist and return the runtime dir path
# Usage: RUNTIME_DIR=$(ralph_core__ensure_runtime_dirs "$REPO_DIR")
ralph_core__ensure_runtime_dirs() {
    local repo_dir="$1"
    local runtime_dir="${RALPH_RUNTIME_DIR:-.ralph}"

    # Convert relative to absolute
    if [[ "$runtime_dir" != /* ]]; then
        runtime_dir="$repo_dir/$runtime_dir"
    fi

    mkdir -p "$runtime_dir/logs"
    echo "$runtime_dir"
}

# =============================================================================
# Logging
# =============================================================================

# Log a message with timestamp
# Usage: ralph_core__log "message" ["$LOG_FILE"]
ralph_core__log() {
    local msg="$1"
    local log_file="${2:-}"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $msg"

    if [[ -n "$log_file" ]]; then
        echo "$line" | tee -a "$log_file"
    else
        echo "$line"
    fi
}

# =============================================================================
# Notifications
# =============================================================================

# Send a notification via notify.sh (best-effort)
# Usage: ralph_core__notify "$REPO_DIR" "emoji" "title" "message"
ralph_core__notify() {
    local repo_dir="$1"
    local emoji="$2"
    local title="$3"
    local message="$4"

    local notify_script="$repo_dir/ralph/bin/notify.sh"
    if [[ -x "$notify_script" ]]; then
        "$notify_script" "$emoji" "$title" "$message" 2>/dev/null || true
    fi
}

# =============================================================================
# Git Helpers
# =============================================================================

# Check if git worktree is clean (no uncommitted changes)
# Usage: if ralph_core__is_git_worktree_clean; then ...
ralph_core__is_git_worktree_clean() {
    git diff --quiet && git diff --cached --quiet && [[ -z "$(git ls-files --others --exclude-standard)" ]]
}

# Get current git branch name
# Usage: branch=$(ralph_core__git_current_branch)
ralph_core__git_current_branch() {
    git branch --show-current 2>/dev/null || echo "unknown"
}

# Check if a remote exists
# Usage: if ralph_core__git_has_remote "origin"; then ...
ralph_core__git_has_remote() {
    local remote="$1"
    git remote get-url "$remote" >/dev/null 2>&1
}

# Sync local branch with remote (fetch + fast-forward or rebase)
# Usage: ralph_core__git_sync_branch "$REPO_DIR" "$branch" "$LOG_FILE"
ralph_core__git_sync_branch() {
    local repo_dir="$1"
    local branch="$2"
    local log_file="${3:-}"
    local remote="${RALPH_GIT_REMOTE:-origin}"

    if ! ralph_core__git_has_remote "$remote"; then
        return 0
    fi

    if ! ralph_core__is_git_worktree_clean; then
        ralph_core__log "Working tree dirty; skipping sync with $remote/$branch" "$log_file"
        return 0
    fi

    if ! git fetch "$remote" "$branch" 2>/dev/null && ! git fetch "$remote" 2>/dev/null; then
        ralph_core__log "git fetch failed; skipping sync" "$log_file"
        return 0
    fi

    local remote_ref="$remote/$branch"
    if ! git show-ref --verify --quiet "refs/remotes/$remote_ref"; then
        return 0
    fi

    local local_sha remote_sha base_sha
    local_sha=$(git rev-parse "$branch" 2>/dev/null || echo "")
    remote_sha=$(git rev-parse "$remote_ref" 2>/dev/null || echo "")
    [[ -z "$local_sha" ]] && return 0
    [[ -z "$remote_sha" ]] && return 0
    [[ "$local_sha" = "$remote_sha" ]] && return 0

    base_sha=$(git merge-base "$branch" "$remote_ref" 2>/dev/null || echo "")
    [[ -z "$base_sha" ]] && return 0

    if [[ "$local_sha" = "$base_sha" ]]; then
        ralph_core__log "Fast-forwarding $branch to $remote_ref" "$log_file"
        git merge --ff-only "$remote_ref" 2>/dev/null || {
            ralph_core__log "Fast-forward failed; manual intervention required" "$log_file"
            return 1
        }
        return 0
    fi

    if [[ "$remote_sha" = "$base_sha" ]]; then
        return 0
    fi

    if [[ "$branch" = "main" ]] || [[ "$branch" = "master" ]]; then
        ralph_core__log "Branch $branch diverged from $remote_ref; merging" "$log_file"
        git merge --no-edit "$remote_ref" 2>/dev/null || return 1
        return 0
    fi

    ralph_core__log "Branch $branch diverged from $remote_ref; rebasing local commits" "$log_file"
    if ! git rebase "$remote_ref" 2>/dev/null; then
        ralph_core__log "Rebase failed; aborting and attempting merge" "$log_file"
        git rebase --abort 2>/dev/null || true
        git merge --no-edit "$remote_ref" 2>/dev/null || return 1
    fi
}

# Push branch to remote (respects RALPH_AUTOPUSH)
# Usage: ralph_core__git_push_branch "$REPO_DIR" "$branch" "$LOG_FILE"
ralph_core__git_push_branch() {
    local repo_dir="$1"
    local branch="$2"
    local log_file="${3:-}"
    local remote="${RALPH_GIT_REMOTE:-origin}"

    if [[ "${RALPH_AUTOPUSH:-false}" != "true" ]]; then
        ralph_core__log "Autopush disabled; skipping push" "$log_file"
        return 0
    fi

    if ! ralph_core__git_has_remote "$remote"; then
        ralph_core__log "No git remote '$remote' configured; skipping push" "$log_file"
        return 0
    fi

    if git push "$remote" "$branch" 2>/dev/null; then
        return 0
    fi

    ralph_core__log "Push failed for $branch; syncing with $remote and retrying..." "$log_file"
    if ! ralph_core__git_sync_branch "$repo_dir" "$branch" "$log_file"; then
        ralph_core__notify "$repo_dir" "🚨" "Ralph Push Failed" "Failed to sync with $remote/$branch. Manual intervention required."
        return 1
    fi

    git push "$remote" "$branch" 2>/dev/null || {
        ralph_core__notify "$repo_dir" "🚨" "Ralph Push Failed" "Failed to push $branch after sync. Manual intervention required."
        return 1
    }
}

# =============================================================================
# Flag Consumption (for daemon coordination)
# =============================================================================

# Consume a flag from a file (e.g., [REPLAN], [DEPLOY], [PAUSE])
# Usage: if ralph_core__consume_flag "$REPO_DIR" "REQUESTS.md" "REPLAN"; then ...
ralph_core__consume_flag() {
    local repo_dir="$1"
    local file_rel="$2"
    local flag="$3"
    local file="$repo_dir/$file_rel"

    grep -q "\\[$flag\\]" "$file" 2>/dev/null || return 1

    # GNU/BSD compatible in-place edit
    sed -i.bak "s/\\[$flag\\]//g" "$file" && rm -f "$file.bak"
    git add "$file_rel" 2>/dev/null || true
    git commit -m "ralph: processed $flag" --allow-empty 2>/dev/null || true
    return 0
}

# Check if a flag exists in a file
# Usage: if ralph_core__has_flag "$REPO_DIR" "REQUESTS.md" "PAUSE"; then ...
ralph_core__has_flag() {
    local repo_dir="$1"
    local file_rel="$2"
    local flag="$3"
    local file="$repo_dir/$file_rel"

    grep -q "\\[$flag\\]" "$file" 2>/dev/null
}

# =============================================================================
# CLI UX Functions
# =============================================================================

# Spinner with step detection for visual feedback
# Usage: ralph_core__spinner_start "Working"
#        ralph_core__spinner_step "Reading files"
#        ralph_core__spinner_stop
_RALPH_SPINNER_PID=""
_RALPH_SPINNER_MSG=""

ralph_core__spinner_start() {
    local msg="${1:-Working}"
    _RALPH_SPINNER_MSG="$msg"

    if [[ -t 1 ]]; then
        (
            local spinchars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            local i=0
            while true; do
                printf "\r\033[K%s %s" "${spinchars:i++%10:1}" "$_RALPH_SPINNER_MSG"
                sleep 0.1
            done
        ) &
        _RALPH_SPINNER_PID=$!
        disown 2>/dev/null || true
    fi
}

ralph_core__spinner_step() {
    local msg="${1:-Working}"
    _RALPH_SPINNER_MSG="$msg"
}

ralph_core__spinner_stop() {
    if [[ -n "$_RALPH_SPINNER_PID" ]]; then
        kill "$_RALPH_SPINNER_PID" 2>/dev/null || true
        wait "$_RALPH_SPINNER_PID" 2>/dev/null || true
        _RALPH_SPINNER_PID=""
        printf "\r\033[K"
    fi
}

# Timer display - shows elapsed time
# Usage: RALPH_START_TIME=$(ralph_core__timer_start)
#        ralph_core__timer_elapsed "$RALPH_START_TIME"  # Returns "05:23"
ralph_core__timer_start() {
    date +%s
}

ralph_core__timer_elapsed() {
    local start_time="$1"
    local now
    now=$(date +%s)
    local elapsed=$((now - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf "%02d:%02d" "$mins" "$secs"
}

# Desktop notification (macOS/Linux compatible)
# Usage: ralph_core__desktop_notify "title" "message"
ralph_core__desktop_notify() {
    local title="$1"
    local message="$2"

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        osascript - "$title" "$message" 2>/dev/null <<'APPLESCRIPT' || true
on run argv
    set theTitle to item 1 of argv
    set theMessage to item 2 of argv
    display notification theMessage with title theTitle
end run
APPLESCRIPT
    elif ralph_core__has_cmd "notify-send"; then
        # Linux with notify-send
        notify-send "$title" "$message" 2>/dev/null || true
    fi
}

# Parse token usage from Claude output (JSON stream format)
# Usage: tokens=$(ralph_core__parse_token_usage "$output_file")
ralph_core__parse_token_usage() {
    local output_file="$1"

    if [[ ! -f "$output_file" ]]; then
        echo "unknown"
        return
    fi

    local input_tokens output_tokens
    input_tokens=$(grep -o '"input_tokens":[0-9]*' "$output_file" 2>/dev/null | tail -1 | grep -o '[0-9]*' || echo "0")
    output_tokens=$(grep -o '"output_tokens":[0-9]*' "$output_file" 2>/dev/null | tail -1 | grep -o '[0-9]*' || echo "0")

    if [[ "$input_tokens" = "0" ]] && [[ "$output_tokens" = "0" ]]; then
        echo "unknown"
    else
        echo "${input_tokens}/${output_tokens}"
    fi
}

# Detect project type from current directory
# Usage: project_type=$(ralph_core__detect_project_type "$REPO_DIR")
ralph_core__detect_project_type() {
    local repo_dir="$1"

    if [[ -f "$repo_dir/package.json" ]]; then
        echo "node"
    elif [[ -f "$repo_dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$repo_dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$repo_dir/pyproject.toml" ]] || [[ -f "$repo_dir/requirements.txt" ]] || [[ -f "$repo_dir/setup.py" ]]; then
        echo "python"
    elif [[ -f "$repo_dir/Gemfile" ]]; then
        echo "ruby"
    elif [[ -f "$repo_dir/build.gradle" ]] || [[ -f "$repo_dir/pom.xml" ]]; then
        echo "java"
    elif [[ -f "$repo_dir/Package.swift" ]]; then
        echo "swift"
    else
        echo "unknown"
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Check if a command exists
# Usage: if ralph_core__has_cmd "jq"; then ...
ralph_core__has_cmd() {
    command -v "$1" &>/dev/null
}

# Require a command, exit with error if not found
# Usage: ralph_core__require_cmd "jq"
ralph_core__require_cmd() {
    local cmd="$1"
    if ! ralph_core__has_cmd "$cmd"; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 127
    fi
}

# Get a value from a JSON file using jq
# Usage: value=$(ralph_core__json_get "file.json" ".key" "default")
ralph_core__json_get() {
    local file="$1"
    local jq_expr="$2"
    local default="${3:-}"

    if [[ ! -f "$file" ]] || ! ralph_core__has_cmd "jq"; then
        echo "$default"
        return 0
    fi

    local result
    result=$(jq -r "$jq_expr // empty" "$file" 2>/dev/null || echo "")

    if [[ -z "$result" ]]; then
        echo "$default"
    else
        echo "$result"
    fi
}

# Compute hash of a string or file (portable: tries md5sum, then shasum, then md5)
# Usage: hash=$(ralph_core__hash "string")
# Usage: hash=$(ralph_core__hash_file "path/to/file")
ralph_core__hash() {
    local input="$1"
    if ralph_core__has_cmd "md5sum"; then
        echo "$input" | md5sum | cut -d' ' -f1
    elif ralph_core__has_cmd "shasum"; then
        echo "$input" | shasum | cut -d' ' -f1
    elif ralph_core__has_cmd "md5"; then
        echo "$input" | md5
    else
        # Fallback: just echo the input (not a hash, but better than nothing)
        echo "$input" | head -c 32
    fi
}

ralph_core__hash_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo ""
        return 1
    fi

    if ralph_core__has_cmd "md5sum"; then
        md5sum "$file" | cut -d' ' -f1
    elif ralph_core__has_cmd "shasum"; then
        shasum "$file" | cut -d' ' -f1
    elif ralph_core__has_cmd "md5"; then
        md5 -q "$file"
    else
        cat "$file" | head -c 32
    fi
}
