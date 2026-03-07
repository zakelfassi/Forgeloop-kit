#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

mkdir -p "$tmp_repo/bin" "$tmp_repo/lib"
cp "$ROOT_DIR/bin/escalate.sh" "$tmp_repo/bin/"
cp "$ROOT_DIR/lib/core.sh" "$tmp_repo/lib/"
cp "$ROOT_DIR/config.sh" "$tmp_repo/"
chmod +x "$tmp_repo/bin/escalate.sh"

json_get() {
  local file="$1"
  local path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$path" "$file"
  else
    python3 - "$file" "$path" <<'PY'
import json
import sys

file_path, expr = sys.argv[1:]
with open(file_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
cur = data
for part in expr.lstrip(".").split("."):
    cur = cur[part]
print(cur)
PY
  fi
}

source "$tmp_repo/lib/core.sh"

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_FAILURE_ESCALATE_AFTER=2
export FORGELOOP_FAILURE_ESCALATION_ACTION=issue

state_file="$FORGELOOP_RUNTIME_DIR/runtime-state.json"
evidence_file="$tmp_repo/evidence.txt"
printf 'CI still failing on the same command\n' > "$evidence_file"

if forgeloop_core__handle_repeated_failure "$tmp_repo" "ci" "CI gate failed on main" "$evidence_file" ""; then
  echo "FAIL: first repeated failure should retry, not escalate" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.status')" != "blocked" ]]; then
  echo "FAIL: first repeated failure should set runtime state to blocked" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.transition')" != "blocked" ]]; then
  echo "FAIL: first repeated failure should record blocked as the transition" >&2
  exit 1
fi

if ! forgeloop_core__handle_repeated_failure "$tmp_repo" "ci" "CI gate failed on main" "$evidence_file" ""; then
  echo "FAIL: second repeated failure should escalate" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.status')" != "awaiting-human" ]]; then
  echo "FAIL: escalated failure should set runtime state to awaiting-human" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.requested_action')" != "issue" ]]; then
  echo "FAIL: runtime state should record requested escalation action" >&2
  exit 1
fi

echo "ok: eval repeated-failure-state"
