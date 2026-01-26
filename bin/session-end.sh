#!/usr/bin/env bash
# =============================================================================
# Session End Hook
# =============================================================================
# Captures knowledge from the session and updates the knowledge base.
# Called after a Ralph loop completes or manually at session end.
#
# Usage:
#   ./ralph/bin/session-end.sh [--capture "decision|pattern|preference|insight"]
#   ./ralph/bin/session-end.sh --update-access
#
# Features:
#   - Updates "last_accessed" dates for used knowledge
#   - Captures new knowledge entries from session
#   - Updates knowledge index
#   - Triggers decay check for stale entries
# =============================================================================

set -euo pipefail

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RALPH_DIR="$REPO_DIR/ralph"

if [[ ! -f "$RALPH_DIR/lib/core.sh" ]]; then
    RALPH_DIR="$REPO_DIR"
fi

source "$RALPH_DIR/lib/core.sh" 2>/dev/null || true

KNOWLEDGE_DIR="$REPO_DIR/system/knowledge"
TODAY=$(date '+%Y-%m-%d')

# =============================================================================
# Date Helpers
# =============================================================================

date_to_epoch() {
    local date_str="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        date -j -f "%Y-%m-%d" "$date_str" "+%s" 2>/dev/null || echo 0
    else
        date -d "$date_str" "+%s" 2>/dev/null || echo 0
    fi
}

days_since() {
    local date_str="$1"
    local entry_epoch today_epoch
    entry_epoch=$(date_to_epoch "$date_str")
    today_epoch=$(date "+%s")
    [[ "$entry_epoch" == "0" ]] && echo 0 && return 0
    echo $(( (today_epoch - entry_epoch) / 86400 ))
}

# =============================================================================
# ID Generation
# =============================================================================

get_next_id() {
    local file="$1"
    local prefix="$2"

    if [[ ! -f "$file" ]]; then
        echo "${prefix}-001"
        return
    fi

    local last_id
    last_id=$(grep -oE "${prefix}-[0-9]{3}" "$file" 2>/dev/null | sort | tail -1 || echo "")

    if [[ -z "$last_id" ]]; then
        echo "${prefix}-001"
        return
    fi

    local num
    num=$(echo "$last_id" | grep -oE "[0-9]{3}" | sed 's/^0*//')
    num=$((num + 1))
    printf "%s-%03d" "$prefix" "$num"
}

# =============================================================================
# Knowledge Capture
# =============================================================================

capture_decision() {
    local title="$1"
    local context="$2"
    local decision="$3"
    local consequences="${4:-}"
    local tags="${5:-general}"

    local file="$KNOWLEDGE_DIR/decisions.md"
    local id
    id=$(get_next_id "$file" "D")

    cat >> "$file" << EOF

### $id | $title
- **tags**: $tags
- **confidence**: medium
- **verified**: false
- **created**: $TODAY
- **last_accessed**: $TODAY

**Context**: $context

**Decision**: $decision

**Consequences**: ${consequences:-To be observed.}

---
EOF

    echo "Captured decision: $id | $title"
}

capture_pattern() {
    local title="$1"
    local pattern="$2"
    local context="$3"
    local implications="${4:-}"
    local tags="${5:-general}"

    local file="$KNOWLEDGE_DIR/patterns.md"
    local id
    id=$(get_next_id "$file" "P")

    cat >> "$file" << EOF

### $id | $title
- **tags**: $tags
- **strength**: weak
- **occurrences**: 1
- **created**: $TODAY
- **last_accessed**: $TODAY

**Pattern**: $pattern

**Context**: $context

**Implications**: ${implications:-Needs more observation.}

---
EOF

    echo "Captured pattern: $id | $title"
}

capture_preference() {
    local title="$1"
    local preference="$2"
    local application="${3:-}"
    local tags="${4:-general}"
    local source="${5:-explicit}"

    local file="$KNOWLEDGE_DIR/preferences.md"
    local id
    id=$(get_next_id "$file" "PR")

    cat >> "$file" << EOF

### $id | $title
- **tags**: $tags
- **source**: $source
- **created**: $TODAY
- **last_accessed**: $TODAY

**Preference**: $preference

**Application**: ${application:-Apply when relevant.}

---
EOF

    echo "Captured preference: $id | $title"
}

capture_insight() {
    local title="$1"
    local insight="$2"
    local evidence="$3"
    local usage="${4:-}"
    local tags="${5:-general}"

    local file="$KNOWLEDGE_DIR/insights.md"
    local id
    id=$(get_next_id "$file" "I")

    cat >> "$file" << EOF

### $id | $title
- **tags**: $tags
- **confidence**: medium
- **verified**: false
- **created**: $TODAY
- **last_accessed**: $TODAY

**Insight**: $insight

**Evidence**: $evidence

**Usage**: ${usage:-Reference as needed.}

---
EOF

    echo "Captured insight: $id | $title"
}

# =============================================================================
# Access Tracking
# =============================================================================

update_last_accessed() {
    local id="$1"

    for file in "$KNOWLEDGE_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        [[ "$(basename "$file")" == "_index.md" ]] && continue
        [[ "$(basename "$file")" == "archive.md" ]] && continue

        if grep -q "^### $id |" "$file" 2>/dev/null; then
            local tmp
            tmp="$(mktemp)"
            awk -v target_id="$id" -v today="$TODAY" '
                BEGIN { in_target=0 }
                /^### / {
                    if ($0 ~ ("^### " target_id " [|]")) in_target=1
                    else in_target=0
                }
                {
                    if (in_target && $0 ~ /^- \*\*last_accessed\*\*:/) {
                        sub(/:.*/, ": " today)
                    } else if (in_target && $0 ~ /^- last_accessed:/) {
                        sub(/:.*/, ": " today)
                    }
                    print
                }
            ' "$file" > "$tmp"
            mv "$tmp" "$file"
            echo "Updated access date for $id"
            return 0
        fi
    done

    echo "Entry not found: $id"
    return 1
}

# =============================================================================
# Decay Check
# =============================================================================

check_decay() {
    local stale_threshold="${RALPH_STALE_THRESHOLD_DAYS:-90}"
    local unverified_threshold="${RALPH_UNVERIFIED_THRESHOLD_DAYS:-60}"

    echo "Checking for stale entries..."

    for file in "$KNOWLEDGE_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        [[ "$(basename "$file")" == "_index.md" ]] && continue
        [[ "$(basename "$file")" == "archive.md" ]] && continue

        local current_id="" current_title="" last_accessed="" created="" verified=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^###[[:space:]]+([A-Za-z][A-Za-z]?-[0-9][0-9][0-9])[[:space:]]*\\|[[:space:]]*(.*)$ ]]; then
                current_id="${BASH_REMATCH[1]}"
                current_title="${BASH_REMATCH[2]}"
                last_accessed=""
                created=""
                verified=""
                continue
            fi

            if [[ "$line" =~ ^-[[:space:]]+\\*\\*last_accessed\\*\\*:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                last_accessed="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-[[:space:]]+last_accessed:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                last_accessed="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-[[:space:]]+\\*\\*created\\*\\*:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                created="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-[[:space:]]+created:[[:space:]]*([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                created="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-[[:space:]]+\\*\\*verified\\*\\*:[[:space:]]*(true|false) ]]; then
                verified="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^-[[:space:]]+verified:[[:space:]]*(true|false) ]]; then
                verified="${BASH_REMATCH[1]}"
            fi

            if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
                if [[ -n "$current_id" ]]; then
                    if [[ -n "$last_accessed" ]]; then
                        local days_ago
                        days_ago=$(days_since "$last_accessed")
                        if [[ "$days_ago" -gt "$stale_threshold" ]]; then
                            echo "  Stale ($days_ago days): $(basename "$file") $current_id | $current_title"
                        fi
                    fi

                    if [[ "${verified:-}" == "false" && -n "$created" ]]; then
                        local age_days
                        age_days=$(days_since "$created")
                        if [[ "$age_days" -gt "$unverified_threshold" ]]; then
                            echo "  Unverified ($age_days days): $(basename "$file") $current_id | $current_title"
                        fi
                    fi
                fi
            fi
        done < "$file"
    done
}

# =============================================================================
# Index Update
# =============================================================================

update_index() {
    local index_file="$KNOWLEDGE_DIR/_index.md"
    [[ ! -f "$index_file" ]] && return

    # Count entries
    local d_count p_count pr_count i_count a_count
    d_count=$(grep -cE "^### D-[0-9]{3}[[:space:]]*[|]" "$KNOWLEDGE_DIR/decisions.md" 2>/dev/null || echo 0)
    p_count=$(grep -cE "^### P-[0-9]{3}[[:space:]]*[|]" "$KNOWLEDGE_DIR/patterns.md" 2>/dev/null || echo 0)
    pr_count=$(grep -cE "^### PR-[0-9]{3}[[:space:]]*[|]" "$KNOWLEDGE_DIR/preferences.md" 2>/dev/null || echo 0)
    i_count=$(grep -cE "^### I-[0-9]{3}[[:space:]]*[|]" "$KNOWLEDGE_DIR/insights.md" 2>/dev/null || echo 0)
    a_count=$(grep -cE "^### [A-Za-z]{1,2}-[0-9]{3}[[:space:]]*[|]" "$KNOWLEDGE_DIR/archive.md" 2>/dev/null || echo 0)

    # Update Quick Stats section (best-effort; preserves the rest of the file)
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "- Decisions:"*) echo "- Decisions: $d_count" ;;
            "- Patterns:"*) echo "- Patterns: $p_count" ;;
            "- Preferences:"*) echo "- Preferences: $pr_count" ;;
            "- Insights:"*) echo "- Insights: $i_count" ;;
            "- Archived:"*) echo "- Archived: $a_count" ;;
            *) echo "$line" ;;
        esac
    done < "$index_file" > "$tmp"
    mv "$tmp" "$index_file"

    echo "Knowledge stats: D=$d_count, P=$p_count, PR=$pr_count, I=$i_count, A=$a_count"
}

# =============================================================================
# Main
# =============================================================================

main() {
    if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
        echo "Knowledge directory not found: $KNOWLEDGE_DIR"
        echo "Run install.sh to create knowledge templates first."
        exit 0
    fi

    local action="${1:-summary}"

    case "$action" in
        --capture)
            local type="${2:-}"
            case "$type" in
                decision)
                    capture_decision "${3:-Untitled}" "${4:-No context}" "${5:-No decision}" "${6:-}" "${7:-}"
                    ;;
                pattern)
                    capture_pattern "${3:-Untitled}" "${4:-No pattern}" "${5:-No context}" "${6:-}" "${7:-}"
                    ;;
                preference)
                    capture_preference "${3:-Untitled}" "${4:-No preference}" "${5:-}" "${6:-}" "${7:-}"
                    ;;
                insight)
                    capture_insight "${3:-Untitled}" "${4:-No insight}" "${5:-No evidence}" "${6:-}" "${7:-}"
                    ;;
                *)
                    echo "Unknown capture type: $type"
                    echo "Usage: $0 --capture <decision|pattern|preference|insight> <args...>"
                    exit 1
                    ;;
            esac
            ;;
        --update-access)
            local id="${2:-}"
            if [[ -z "$id" ]]; then
                echo "Usage: $0 --update-access <ID>"
                exit 1
            fi
            update_last_accessed "$id"
            ;;
        --check-decay)
            check_decay
            ;;
        summary|*)
            echo "Session end summary:"
            update_index
            check_decay
            ;;
    esac
}

main "$@"
