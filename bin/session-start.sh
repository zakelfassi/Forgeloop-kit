#!/usr/bin/env bash
# =============================================================================
# Session Start Hook
# =============================================================================
# Loads knowledge context for a Ralph session.
# Intended for use by loop.sh and manual invocation.
#
# Usage:
#   ./ralph/bin/session-start.sh [--quiet] [--no-stdout] [--print-path]
#
# Output:
#   - By default, prints session context to stdout (suitable for inclusion in prompts)
#   - Writes session context to: $RALPH_RUNTIME_DIR/session-context.md (or .ralph/session-context.md)
#   - Note: exporting env vars from an executed script does not affect the parent shell.
# =============================================================================

set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RALPH_DIR="$REPO_DIR/ralph"

# Prefer a vendored kit at $REPO_DIR/ralph, otherwise fall back to repo root.
if [[ ! -f "$RALPH_DIR/lib/core.sh" ]]; then
    RALPH_DIR="$REPO_DIR"
fi

# shellcheck disable=SC1090
source "$RALPH_DIR/lib/core.sh" 2>/dev/null || true

KNOWLEDGE_DIR="$REPO_DIR/system/knowledge"
EXPERTS_DIR="$REPO_DIR/system/experts"
RUNTIME_DIR=""
SESSION_CONTEXT_FILE=""

QUIET=false
NO_STDOUT=false
PRINT_PATH=false

if [[ "${RALPH_SESSION_QUIET:-}" == "true" ]]; then
    QUIET=true
fi
if [[ "${RALPH_SESSION_NO_STDOUT:-}" == "true" ]]; then
    NO_STDOUT=true
fi

usage() {
    cat <<'USAGE'
Usage:
  session-start.sh [--quiet] [--no-stdout] [--print-path]

Flags:
  --quiet       Suppress status messages (sent to stderr)
  --no-stdout   Do not print the context content to stdout
  --print-path  Print the generated context file path to stdout
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=true; shift ;;
        --no-stdout) NO_STDOUT=true; shift ;;
        --print-path) PRINT_PATH=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Unknown arg: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Resolve runtime directory (prefer core helper if available)
if declare -F ralph_core__ensure_runtime_dirs >/dev/null 2>&1; then
    RUNTIME_DIR=$(ralph_core__ensure_runtime_dirs "$REPO_DIR")
else
    local_runtime_dir="${RALPH_RUNTIME_DIR:-.ralph}"
    if [[ "$local_runtime_dir" != /* ]]; then
        local_runtime_dir="$REPO_DIR/$local_runtime_dir"
    fi
    mkdir -p "$local_runtime_dir/logs" 2>/dev/null || true
    RUNTIME_DIR="$local_runtime_dir"
fi

SESSION_CONTEXT_FILE="$RUNTIME_DIR/session-context.md"
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true

# =============================================================================
# Knowledge Loading
# =============================================================================

extract_sections_by_meta() {
    local file="$1"
    local key="$2"
    local value="$3"
    local max_sections="${4:-3}"
    local max_lines="${5:-120}"

    [[ -f "$file" ]] || return 0

    awk -v key="$key" -v val="$value" -v limit="$max_sections" '
        function section_matches(s) {
            return (s ~ ("\\*\\*" key "\\*\\*:[[:space:]]*" val) || s ~ (key ":[[:space:]]*" val))
        }
        function flush() {
            if (!in_section) return
            if (section_matches(section)) {
                print section "\n"
                count++
            }
        }
        BEGIN { in_section=0; section=""; count=0 }
        /^### [A-Za-z][A-Za-z]?-[0-9][0-9][0-9][[:space:]]*[|]/ {
            if (in_section) flush()
            if (count >= limit) exit
            in_section=1
            section=$0 "\n"
            next
        }
        {
            if (in_section) section=section $0 "\n"
        }
        END { if (count < limit && in_section) flush() }
    ' "$file" | head -n "$max_lines"
}

load_high_priority_knowledge() {
    local output=""

    # Load verified high-confidence decisions
    if [[ -f "$KNOWLEDGE_DIR/decisions.md" ]]; then
        local decisions
        decisions=$(extract_sections_by_meta "$KNOWLEDGE_DIR/decisions.md" "confidence" "high" 3 120 || true)
        if [[ -n "$decisions" ]]; then
            output+="## Active Decisions\n$decisions\n\n"
        fi
    fi

    # Load strong patterns
    if [[ -f "$KNOWLEDGE_DIR/patterns.md" ]]; then
        local patterns
        patterns=$(extract_sections_by_meta "$KNOWLEDGE_DIR/patterns.md" "strength" "strong" 3 100 || true)
        if [[ -n "$patterns" ]]; then
            output+="## Observed Patterns\n$patterns\n\n"
        fi
    fi

    # Load explicit preferences (always load these - they're user-stated)
    if [[ -f "$KNOWLEDGE_DIR/preferences.md" ]]; then
        local prefs
        prefs=$(extract_sections_by_meta "$KNOWLEDGE_DIR/preferences.md" "source" "explicit" 5 120 || true)
        if [[ -n "$prefs" ]]; then
            output+="## User Preferences\n$prefs\n\n"
        fi
    fi

    # Load recent high-confidence insights
    if [[ -f "$KNOWLEDGE_DIR/insights.md" ]]; then
        local insights
        insights=$(extract_sections_by_meta "$KNOWLEDGE_DIR/insights.md" "confidence" "high" 3 120 || true)
        if [[ -n "$insights" ]]; then
            output+="## Codebase Insights\n$insights\n\n"
        fi
    fi

    echo -e "$output"
}

# =============================================================================
# Expert Detection
# =============================================================================

detect_relevant_experts() {
    local task_keywords="${1:-}"
    local experts=""

    # Check for security keywords
    if echo "$task_keywords" | grep -qiE "auth|security|GDPR|HIPAA|encrypt|vulnerab"; then
        [[ -f "$EXPERTS_DIR/security.md" ]] && experts+="security "
    fi

    # Check for testing keywords
    if echo "$task_keywords" | grep -qiE "test|QA|coverage|e2e|unit|integration"; then
        [[ -f "$EXPERTS_DIR/testing.md" ]] && experts+="testing "
    fi

    # Check for architecture keywords
    if echo "$task_keywords" | grep -qiE "api|schema|scalab|systems|microservice|architect"; then
        [[ -f "$EXPERTS_DIR/architecture.md" ]] && experts+="architecture "
    fi

    # Check for devops keywords
    if echo "$task_keywords" | grep -qiE "deploy|CI/CD|docker|k8s|infra|SRE"; then
        [[ -f "$EXPERTS_DIR/devops.md" ]] && experts+="devops "
    fi

    # Check for UX/design keywords
    if echo "$task_keywords" | grep -qiE "ui|ux|design|a11y|accessib|frontend|css|tailwind|component"; then
        [[ -f "$EXPERTS_DIR/design.md" ]] && experts+="design "
    fi

    # Check for documentation keywords
    if echo "$task_keywords" | grep -qiE "docs|documentation|readme|changelog|runbook|spec"; then
        [[ -f "$EXPERTS_DIR/documentation.md" ]] && experts+="documentation "
    fi

    # Check for product keywords
    if echo "$task_keywords" | grep -qiE "product|requirements|mvp|scope|user story|roadmap|priorit"; then
        [[ -f "$EXPERTS_DIR/product.md" ]] && experts+="product "
    fi

    # Default to implementation for code tasks
    if echo "$task_keywords" | grep -qiE "code|refactor|implement|debug|fix|bug"; then
        [[ -f "$EXPERTS_DIR/implementation.md" ]] && experts+="implementation "
    fi

    echo "$experts"
}

load_experts() {
    local expert_names="${1:-}"
    local output=""

    for expert in $expert_names; do
        local expert_file="$EXPERTS_DIR/${expert}.md"
        if [[ -f "$expert_file" ]]; then
            # Load the first section (personas and principles) only
            local content
            content=$(head -80 "$expert_file")
            local expert_title
            expert_title=$(printf '%s' "$expert" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
            output+="## Expert: $expert_title\n$content\n\n"
        fi
    done

    echo -e "$output"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local task_context="${RALPH_TASK_CONTEXT:-}"
    local output=""
    local experts=""

    # Header
    output+="# Session Context\n"
    output+="Loaded at: $(date '+%Y-%m-%d %H:%M:%S')\n\n"

    # Load knowledge if available
    if [[ -d "$KNOWLEDGE_DIR" ]]; then
        output+="# Persistent Knowledge\n\n"
        output+="$(load_high_priority_knowledge)"
    fi

    # Detect and load relevant experts
    if [[ -d "$EXPERTS_DIR" ]]; then
        experts=$(detect_relevant_experts "$task_context")
        if [[ -n "$experts" ]]; then
            output+="# Domain Experts\n\n"
            output+="$(load_experts "$experts")"
        fi
    fi

    # Write to file and export path
    echo -e "$output" > "$SESSION_CONTEXT_FILE"
    export RALPH_SESSION_CONTEXT="$SESSION_CONTEXT_FILE"

    if [[ "$PRINT_PATH" == "true" ]]; then
        echo "$SESSION_CONTEXT_FILE"
        return 0
    fi

    if [[ "$NO_STDOUT" != "true" ]]; then
        echo -e "$output"
    fi

    if [[ "$QUIET" != "true" ]]; then
        echo "Session context written: $SESSION_CONTEXT_FILE" >&2
        echo "Experts: ${experts:-none detected}" >&2
    fi
}

main "$@"
