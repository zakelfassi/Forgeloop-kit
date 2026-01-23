#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RALPH_RUNTIME_DIR
RALPH_RUNTIME_DIR="$(mktemp -d)"
export RALPH_QUESTIONS_FILE=".tmp_questions.test.md"

cleanup() {
    rm -rf "$RALPH_RUNTIME_DIR"
    rm -f "$ROOT_DIR/$RALPH_QUESTIONS_FILE"
}
trap cleanup EXIT

source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/bin/ralph-daemon.sh"

assert_eq() {
    local expected="$1"
    local actual="$2"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: expected [$expected], got [$actual]" >&2
        exit 1
    fi
}

questions_path="$REPO_DIR/$QUESTIONS_FILE"

rm -f "$questions_path"
assert_eq "none" "$(get_blocker_hash)"

cat > "$questions_path" <<'EOF'
## Q-1
- ✅ Answered
EOF
assert_eq "none" "$(get_blocker_hash)"

cat > "$questions_path" <<'EOF'
## Q-3
- ⏳ Awaiting response

## Q-2
- ✅ Answered

## Q-1
- ⏳ Awaiting response
EOF

expected_hash=$(ralph_core__hash $'Q-1\nQ-3')
assert_eq "$expected_hash" "$(get_blocker_hash)"

echo "ok: blocker hash"
