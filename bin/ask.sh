#!/bin/bash
# Ask a question via Slack and log it for tracking
# Usage: ./forgeloop/bin/ask.sh "category" "question"
# Categories: blocked, clarification, decision, review

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
FORGELOOP_DIR="$REPO_DIR/forgeloop"
if [[ ! -f "$FORGELOOP_DIR/config.sh" ]]; then
    FORGELOOP_DIR="$REPO_DIR"
fi
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true
source "$FORGELOOP_DIR/lib/core.sh"
source "$REPO_DIR/.env.local" 2>/dev/null || true

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "Error: SLACK_WEBHOOK_URL not set"
    exit 1
fi

category="${1:-question}"
question="${2:-No question provided}"
host=$(hostname)
ts=$(date '+%Y-%m-%d %H:%M:%S')
question_id=$(date '+%s')

QUESTIONS_FILE_REL="${FORGELOOP_QUESTIONS_FILE:-QUESTIONS.md}"
QUESTIONS_FILE="$REPO_DIR/$QUESTIONS_FILE_REL"

# Map category to emoji
case "$category" in
    blocked)        emoji="🚫" ;;
    clarification)  emoji="❓" ;;
    decision)       emoji="🤔" ;;
    review)         emoji="👀" ;;
    *)              emoji="💬" ;;
esac

# Ensure file exists
mkdir -p "$(dirname "$QUESTIONS_FILE")"
touch "$QUESTIONS_FILE"

# Log question
{
    echo ""
    echo "## Q-$question_id ($ts)"
    echo "**Category**: $category"
    echo "**Question**: $question"
    echo "**Status**: ⏳ Awaiting response"
    echo ""
    echo "**Answer**:"
    echo ""
    echo "---"
} >> "$QUESTIONS_FILE"

# Commit the question (best-effort)
cd "$REPO_DIR"
git add "$QUESTIONS_FILE_REL" 2>/dev/null || true
git commit -m "forgeloop: question Q-$question_id ($category)" --allow-empty 2>/dev/null || true

# Push if remote exists (best-effort)
REMOTE="${FORGELOOP_GIT_REMOTE:-origin}"
BRANCH="$(git branch --show-current 2>/dev/null || echo "")"
if [ -n "$BRANCH" ] && git remote get-url "$REMOTE" >/dev/null 2>&1; then
    git push "$REMOTE" "$BRANCH" 2>/dev/null || true
fi

# Post to Slack
text="$emoji *Forgeloop needs input* [$category]\\n\\n$question\\n\\n_Reply by editing $QUESTIONS_FILE_REL (Q-$question_id) and pushing to git_\\n_${host} • ${ts}_"

payload=$(forgeloop_core__json_slack_text_payload "$text")

curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-type: application/json' \
    --data-binary "$payload"

echo ""
echo "Question Q-$question_id posted to Slack and logged to $QUESTIONS_FILE_REL"
