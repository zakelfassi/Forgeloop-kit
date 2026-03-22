#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/core.sh"

repo_dir="$(mktemp -d)"
trap 'rm -rf "$repo_dir"' EXIT
export FORGELOOP_RUNTIME_DIR="$repo_dir/.forgeloop-test"

claim_path="$(forgeloop_core__active_runtime_path "$repo_dir")"
if command -v python3 >/dev/null 2>&1; then
  host_name="$(python3 - <<'PY'
import socket
print(socket.gethostname().split('.')[0].strip().lower() or 'unknown')
PY
)"
else
  host_name="$(hostname 2>/dev/null | awk -F. '{print tolower($1)}')"
  host_name="${host_name:-unknown}"
fi

claim_id="$(forgeloop_core__active_runtime_claim_begin "$repo_dir" "bash" "loop" "build" "main")"
[[ -n "$claim_id" ]]
grep -q '"claim_id":' "$claim_path"
forgeloop_core__active_runtime_claim_end "$repo_dir" "$claim_id"
[[ ! -f "$claim_path" ]]

cat > "$claim_path" <<JSON
{
  "schema_version": 2,
  "claim_id": "rt-live-conflict",
  "owner": "elixir",
  "surface": "daemon",
  "mode": "build",
  "branch": "main",
  "pid": $$,
  "process_pid": null,
  "host": "$host_name",
  "started_at": "2026-03-22T00:00:00Z",
  "updated_at": "2026-03-22T00:00:00Z"
}
JSON

if forgeloop_core__active_runtime_claim_begin "$repo_dir" "bash" "loop" "build" "main" >/dev/null 2>&1; then
  echo "FAIL: live same-host claim should block bash reclaim" >&2
  exit 1
fi

cat > "$claim_path" <<JSON
{
  "schema_version": 2,
  "claim_id": "rt-dead-claim",
  "owner": "bash",
  "surface": "daemon",
  "mode": "build",
  "branch": "main",
  "pid": 999999,
  "process_pid": null,
  "host": "$host_name",
  "started_at": "2026-03-22T00:00:00Z",
  "updated_at": "2026-03-22T00:00:00Z"
}
JSON

reclaimed_id="$(forgeloop_core__active_runtime_claim_begin "$repo_dir" "bash" "loop" "build" "main")"
[[ -n "$reclaimed_id" ]]
forgeloop_core__active_runtime_claim_end "$repo_dir" "$reclaimed_id"
[[ ! -f "$claim_path" ]]

printf '{broken\n' > "$claim_path"
if forgeloop_core__active_runtime_claim_begin "$repo_dir" "bash" "loop" "build" "main" >/dev/null 2>&1; then
  echo "FAIL: malformed claim should fail closed" >&2
  exit 1
fi

echo "ok: runtime ownership reclaim"
