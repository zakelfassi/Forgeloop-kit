#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_RUNTIME_SURFACE="loop"
export FORGELOOP_RUNTIME_MODE="build"
export FORGELOOP_RUNTIME_BRANCH="main"

"$tmp_repo/forgeloop/bin/escalate.sh" "ci" "CI gate failed on main" "issue" "" "3" >/dev/null

state_file="$FORGELOOP_RUNTIME_DIR/runtime-state.json"

python3 - <<'PY' "$state_file"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

assert data["status"] == "awaiting-human", data
assert data["transition"] == "escalated", data
assert data["surface"] == "loop", data
assert data["mode"] == "build", data
assert data["requested_action"] == "issue", data
PY

source "$tmp_repo/forgeloop/lib/core.sh"
forgeloop_core__set_runtime_state "$tmp_repo" "recovered" "loop" "build" "Operator cleared pause" "recovered" "" "main"
forgeloop_core__set_runtime_state "$tmp_repo" "idle" "loop" "build" "Loop completed after recovery" "completed" "" "main"

python3 - <<'PY' "$state_file"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

assert data["status"] == "idle", data
assert data["previous_status"] == "recovered", data
assert data["transition"] == "completed", data
PY

echo "ok: runtime state model"
