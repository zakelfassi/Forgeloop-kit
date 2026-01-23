#!/bin/bash
set -euo pipefail

# =============================================================================
# Ralph Report Ingestion
# =============================================================================
# Analyzes a report via LLM and appends a formatted request to REQUESTS.md.
# Supports idempotent ingestion via content hashing.
#
# Usage:
#   ./ralph/bin/ingest-report.sh --report reports/daily.md
#   ./ralph/bin/ingest-report.sh --reports-dir reports --latest
#   ./ralph/bin/ingest-report.sh --report reports/daily.md --mode plan-work
#
# Options:
#   --report <path>       Path to a specific report file
#   --reports-dir <dir>   Directory containing reports (default: reports)
#   --latest              Use the most recently modified report in the directory
#   --requests <path>     Path to REQUESTS.md (default: from config)
#   --mode <mode>         Output mode: request (default) or plan-work
#   --dry-run             Print what would be appended without writing
#   --json-out <path>     Save the raw LLM JSON response
#   --force               Skip idempotency check, ingest even if already processed
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

# Setup runtime directories
RUNTIME_DIR=$(ralph_core__ensure_runtime_dirs "$REPO_DIR")
LOG_FILE="${RALPH_INGEST_LOG_FILE:-$RUNTIME_DIR/logs/ingest.log}"

# Defaults
REPORTS_DIR="${RALPH_REPORTS_DIR:-reports}"
REQUESTS_FILE="${RALPH_REQUESTS_FILE:-REQUESTS.md}"
MODE="request"
DRY_RUN=false
FORCE=false
REPORT_PATH=""
JSON_OUT=""

log() { ralph_core__log "$1" "$LOG_FILE"; }
notify() { ralph_core__notify "$REPO_DIR" "$@"; }

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --report)
            REPORT_PATH="$2"
            shift 2
            ;;
        --reports-dir)
            REPORTS_DIR="$2"
            shift 2
            ;;
        --latest)
            # Will be resolved after args are parsed
            REPORT_PATH="__LATEST__"
            shift
            ;;
        --requests)
            REQUESTS_FILE="$2"
            shift 2
            ;;
        --mode)
            MODE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --json-out)
            JSON_OUT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --report <path> [--mode request|plan-work] [--dry-run]"
            echo "       $0 --reports-dir <dir> --latest [--mode request|plan-work]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Report Selection
# =============================================================================

select_report() {
    if [[ "$REPORT_PATH" == "__LATEST__" ]]; then
        # Find most recently modified report in directory
        local dir="$REPO_DIR/$REPORTS_DIR"
        if [[ ! -d "$dir" ]]; then
            echo "Error: Reports directory not found: $dir" >&2
            exit 1
        fi

        # Find latest .md file by modification time
        REPORT_PATH=$(find "$dir" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null | \
                      xargs -0 ls -t 2>/dev/null | head -1 || echo "")

        if [[ -z "$REPORT_PATH" ]]; then
            echo "Error: No report files found in $dir" >&2
            exit 1
        fi
    fi

    # Resolve relative paths
    if [[ "$REPORT_PATH" != /* ]]; then
        REPORT_PATH="$REPO_DIR/$REPORT_PATH"
    fi

    if [[ ! -f "$REPORT_PATH" ]]; then
        echo "Error: Report file not found: $REPORT_PATH" >&2
        exit 1
    fi

    echo "$REPORT_PATH"
}

# =============================================================================
# Idempotency Check
# =============================================================================

get_report_hash() {
    local report_path="$1"
    ralph_core__hash_file "$report_path" | cut -c1-12
}

is_already_ingested() {
    local hash="$1"
    local requests_path="$REPO_DIR/$REQUESTS_FILE"

    if [[ ! -f "$requests_path" ]]; then
        return 1  # Not ingested (file doesn't exist)
    fi

    grep -q "Source: report:$hash" "$requests_path" 2>/dev/null
}

# =============================================================================
# LLM Analysis
# =============================================================================

analyze_report() {
    local report_path="$1"
    local report_content
    report_content=$(cat "$report_path")

    # Build prompt for analysis
    local prompt="You are analyzing a report to identify the #1 most actionable item.

Read this report and identify the highest priority item that should be worked on.

CONSTRAINTS:
- Must be completable in a few hours of focused work
- Must be a clear, specific task (not vague)
- Prefer fixes over new features
- Prefer high-impact, low-effort items
- Focus on improvements, bug fixes, or configuration changes

REPORT:
$report_content

Respond with ONLY a JSON object (no markdown, no code fences):
{
  \"priority_item\": \"Brief title of the item\",
  \"description\": \"2-3 sentence description of what needs to be done\",
  \"rationale\": \"Why this is the #1 priority based on the report\",
  \"work_scope\": \"Single sentence scope for plan-work prompt\",
  \"acceptance_criteria\": [\"List of 3-5 specific, verifiable criteria\"],
  \"priority\": \"high\",
  \"type\": \"fix\"
}"

    # Use claude/codex CLI for analysis
    local result
    result=$(echo "$prompt" | ralph_llm__exec "$REPO_DIR" "stdin" "plan" "" "$LOG_FILE" 2>&1)

    # Try to extract JSON from result
    local json_text
    json_text=$(echo "$result" | grep -E '^\{' | head -1 || echo "")

    if [[ -z "$json_text" ]]; then
        # Try to find JSON block in output
        json_text=$(echo "$result" | sed -n '/^{/,/^}/p' | head -20)
    fi

    if ! echo "$json_text" | jq . >/dev/null 2>&1; then
        echo "Error: Could not parse LLM response as JSON" >&2
        echo "Response: $result" >&2
        exit 1
    fi

    echo "$json_text"
}

# =============================================================================
# Output Formatting
# =============================================================================

format_request() {
    local json="$1"
    local hash="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local title description priority type rationale acceptance
    title=$(echo "$json" | jq -r '.priority_item // "Untitled"')
    description=$(echo "$json" | jq -r '.description // ""')
    priority=$(echo "$json" | jq -r '.priority // "medium"')
    type=$(echo "$json" | jq -r '.type // "task"')
    rationale=$(echo "$json" | jq -r '.rationale // ""')

    # Format acceptance criteria as bullet list
    acceptance=$(echo "$json" | jq -r '.acceptance_criteria[]? // empty' | while read -r line; do
        echo "- $line"
    done)

    cat << EOF

## $title
- Priority: $priority
- Type: $type

$description

**Rationale:** $rationale

### Acceptance Criteria
$acceptance

---
Source: report:$hash
CreatedAt: $timestamp
EOF
}

format_plan_work_scope() {
    local json="$1"
    echo "$json" | jq -r '.work_scope // .description // "Complete the prioritized task from the report"'
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Select report
    REPORT_PATH=$(select_report)
    log "Selected report: $REPORT_PATH"

    # Compute hash for idempotency
    local report_hash
    report_hash=$(get_report_hash "$REPORT_PATH")
    log "Report hash: $report_hash"

    # Check if already ingested
    if [[ "$FORCE" != "true" ]] && is_already_ingested "$report_hash"; then
        log "Report already ingested (hash: $report_hash). Use --force to re-ingest."
        echo "Report already ingested. Use --force to re-ingest."
        exit 0
    fi

    # Analyze report
    log "Analyzing report..."
    local analysis_json
    analysis_json=$(analyze_report "$REPORT_PATH")

    # Save JSON output if requested
    if [[ -n "$JSON_OUT" ]]; then
        echo "$analysis_json" > "$JSON_OUT"
        log "Saved analysis JSON to: $JSON_OUT"
    fi

    # Format and output based on mode
    case "$MODE" in
        request)
            local formatted_request
            formatted_request=$(format_request "$analysis_json" "$report_hash")

            if [[ "$DRY_RUN" == "true" ]]; then
                echo "=== DRY RUN: Would append to $REQUESTS_FILE ==="
                echo "$formatted_request"
            else
                local requests_path="$REPO_DIR/$REQUESTS_FILE"
                echo "$formatted_request" >> "$requests_path"
                log "Appended request to $REQUESTS_FILE"
                notify "📥" "Report Ingested" "Added new request from report"

                # Optionally trigger replan
                if [[ "${RALPH_INGEST_TRIGGER_REPLAN:-false}" == "true" ]]; then
                    echo "[REPLAN]" >> "$requests_path"
                    log "Added [REPLAN] trigger"
                fi

                echo "Request appended to $REQUESTS_FILE"
            fi
            ;;

        plan-work)
            local work_scope
            work_scope=$(format_plan_work_scope "$analysis_json")

            if [[ "$DRY_RUN" == "true" ]]; then
                echo "=== DRY RUN: Would run plan-work with scope ==="
                echo "$work_scope"
            else
                log "Running plan-work with scope: $work_scope"
                "$REPO_DIR/ralph/bin/loop.sh" plan-work "$work_scope" 1
            fi
            ;;

        *)
            echo "Unknown mode: $MODE" >&2
            exit 1
            ;;
    esac
}

main
