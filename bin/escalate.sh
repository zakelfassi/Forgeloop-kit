#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"

REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true
if [[ -f "$REPO_DIR/.env.local" ]]; then
    source "$REPO_DIR/.env.local"
fi

kind="${1:-spin}"
summary="${2:-Forgeloop detected a repeated failure}"
requested_action="${3:-${FORGELOOP_FAILURE_ESCALATION_ACTION:-issue}}"
evidence_file="${4:-}"
repeat_count="${5:-1}"

timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
id="$(date '+%s')"
host="$(hostname)"

QUESTIONS_FILE_REL="${FORGELOOP_QUESTIONS_FILE:-QUESTIONS.md}"
REQUESTS_FILE_REL="${FORGELOOP_REQUESTS_FILE:-REQUESTS.md}"
ESCALATIONS_FILE_REL="${FORGELOOP_ESCALATIONS_FILE:-ESCALATIONS.md}"

QUESTIONS_FILE="$REPO_DIR/$QUESTIONS_FILE_REL"
REQUESTS_FILE="$REPO_DIR/$REQUESTS_FILE_REL"
ESCALATIONS_FILE="$REPO_DIR/$ESCALATIONS_FILE_REL"

mkdir -p "$(dirname "$QUESTIONS_FILE")" "$(dirname "$ESCALATIONS_FILE")" "$(dirname "$REQUESTS_FILE")"
touch "$QUESTIONS_FILE" "$ESCALATIONS_FILE" "$REQUESTS_FILE"

surface="${FORGELOOP_RUNTIME_SURFACE:-loop}"
mode="${FORGELOOP_RUNTIME_MODE:-build}"
branch="${FORGELOOP_RUNTIME_BRANCH:-$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "")}"

case "$requested_action" in
    pr)
        action_label="push a PR with the fix"
        suggested_command='gh pr create --fill'
        ;;
    review)
        action_label="review the draft and decide the next move"
        suggested_command='gh pr comment <pr-number> --body-file .forgeloop/escalation-note.md'
        ;;
    rerun)
        action_label="inspect the failure, fix it, and rerun the loop"
        suggested_command='./forgeloop/bin/loop.sh 1'
        ;;
    issue|*)
        action_label="file an issue or start a focused fix branch"
        suggested_command='gh issue create --title "Forgeloop spin: <summary>" --body-file .forgeloop/escalation-note.md'
        ;;
esac

evidence_note="No evidence file captured."
if [[ -n "$evidence_file" ]]; then
    evidence_note="$evidence_file"
fi

if ! grep -q '\[PAUSE\]' "$REQUESTS_FILE" 2>/dev/null; then
    printf '\n[PAUSE]\n' >> "$REQUESTS_FILE"
fi

forgeloop_core__set_runtime_state "$REPO_DIR" "awaiting-human" "$surface" "$mode" "$summary" "escalated" "$requested_action" "$branch"

{
    echo ""
    echo "## Q-$id ($timestamp)"
    echo "**Category**: blocked"
    echo "**Question**: Forgeloop stopped after repeated \`$kind\` failure ($repeat_count x): $summary"
    echo "**Status**: ⏳ Awaiting response"
    echo ""
    echo "**Suggested action**: Please $action_label."
    echo "**Suggested command**: \`$suggested_command\`"
    echo "**Escalation log**: \`$ESCALATIONS_FILE_REL\`"
    echo "**Evidence**: \`$evidence_note\`"
    echo ""
    echo "**Answer**:"
    echo ""
    echo "---"
} >> "$QUESTIONS_FILE"

{
    echo ""
    echo "## E-$id ($timestamp)"
    echo "- Kind: \`$kind\`"
    echo "- Repeat count: \`$repeat_count\`"
    echo "- Requested action: \`$requested_action\`"
    echo "- Summary: $summary"
    echo "- Evidence: \`$evidence_note\`"
    echo "- Host: \`$host\`"
    echo ""
    echo "### Draft"
    echo "Forgeloop hit the same \`$kind\` failure $repeat_count times and paused itself."
    echo ""
    echo "Suggested next move: $action_label."
    echo ""
    echo "Suggested command:"
    echo "\`$suggested_command\`"
    echo ""
    echo "Notes:"
    echo "- Inspect the evidence before resuming."
    echo "- Remove \`[PAUSE]\` from \`$REQUESTS_FILE_REL\` when ready to continue."
    echo "- Mark the matching question in \`$QUESTIONS_FILE_REL\` as answered when the operator has decided."
    echo ""
    echo "---"
} >> "$ESCALATIONS_FILE"

forgeloop_core__notify "$REPO_DIR" "🧯" "Forgeloop Needs Help" "Repeated $kind failure. Drafted next steps in $ESCALATIONS_FILE_REL and paused the daemon."

echo "Escalation drafted in $ESCALATIONS_FILE_REL"
