#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

cat > "$tmp_repo/QUESTIONS.md" <<'EOF'
## Q-1 (2026-03-05 00:00:00)
**Category**: blocked
**Question**: Human input required
**Status**: ⏳ Awaiting response

**Answer**:
EOF

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_MAX_BLOCKED_ITERATIONS=1

source "$tmp_repo/forgeloop/bin/forgeloop-daemon.sh"

if ! check_blocker_loop; then
    echo "FAIL: daemon should detect repeated blocker at threshold" >&2
    exit 1
fi

pause_for_blocker

if ! grep -q '\[PAUSE\]' "$tmp_repo/REQUESTS.md"; then
    echo "FAIL: daemon blocker escalation should pause via REQUESTS.md" >&2
    exit 1
fi

if ! grep -q 'same unanswered blocker' "$tmp_repo/ESCALATIONS.md"; then
    echo "FAIL: daemon blocker escalation should draft a blocker handoff" >&2
    exit 1
fi

python3 - <<'PY' "$FORGELOOP_RUNTIME_DIR/runtime-state.json"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

assert data["status"] == "awaiting-human", data
assert data["surface"] == "daemon", data
assert data["transition"] == "escalated", data
assert data["requested_action"] == "review", data
PY

echo "ok: daemon blocker escalation"
