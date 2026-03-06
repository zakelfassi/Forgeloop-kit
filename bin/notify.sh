#!/bin/bash
# Manual notification script (Slack Incoming Webhook)
# Usage: ./forgeloop/bin/notify.sh "emoji" "title" "message"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"
REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
if [[ -f "$REPO_DIR/.env.local" ]]; then
    source "$REPO_DIR/.env.local"
fi

if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    echo "Error: SLACK_WEBHOOK_URL not set"
    echo "Create .env.local with: SLACK_WEBHOOK_URL=your-webhook-url"
    exit 1
fi

emoji="${1:-📢}"
title="${2:-Notification}"
message="${3:-No message provided}"
host=$(hostname)
ts=$(date '+%Y-%m-%d %H:%M:%S')

text="$emoji *$title*\n$message\n_${host} • ${ts}_"

payload=$(forgeloop_core__json_slack_text_payload "$text")

curl -s -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-type: application/json' \
    --data-binary "$payload"

echo ""
echo "Notification sent!"
