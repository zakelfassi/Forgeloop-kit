#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PORT="${FORGELOOP_E2E_PORT:-4047}"
HOST="${FORGELOOP_E2E_HOST:-127.0.0.1}"
BASE_URL="http://${HOST}:${PORT}"
LOG_DIR="${FORGELOOP_E2E_LOG_DIR:-/tmp/forgeloop-agent-browser}"
SESSION_NAME="${FORGELOOP_E2E_SESSION:-forgeloop-hud-contract}"
BROWSER_WAIT_MS="${FORGELOOP_E2E_WAIT_MS:-1500}"
SCREENSHOT_PATH="${FORGELOOP_E2E_SCREENSHOT:-${LOG_DIR}/$(date +%Y%m%d-%H%M%S)-hud-contract.png}"
SERVICE_LOG="${LOG_DIR}/hud-contract-service.log"

mkdir -p "$LOG_DIR"

cleanup() {
  agent-browser --session "$SESSION_NAME" close >/dev/null 2>&1 || true

  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[hud-contract] missing required command: $name" >&2
    exit 1
  fi
}

assert_json_value() {
  local desc="$1"
  local path="$2"
  local filter="$3"
  local expected="$4"
  local actual
  actual=$(curl -fsS "$BASE_URL$path" | jq -r "$filter")
  if [[ "$actual" != "$expected" ]]; then
    echo "[hud-contract] ${desc} failed: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  echo "[hud-contract] ✅ ${desc}"
}

assert_visible() {
  local desc="$1"
  local selector="$2"
  if ! agent-browser --session "$SESSION_NAME" is visible "$selector" >/dev/null 2>&1; then
    echo "[hud-contract] ${desc} failed: selector not visible: $selector" >&2
    exit 1
  fi
  echo "[hud-contract] ✅ ${desc}"
}

assert_text_contains() {
  local desc="$1"
  local selector="$2"
  local expected="$3"
  local text
  text=$(agent-browser --session "$SESSION_NAME" get text "$selector" 2>/dev/null || true)
  if ! printf '%s' "$text" | grep -Fqi -- "$expected"; then
    echo "[hud-contract] ${desc} failed: expected '$expected' in '$text'" >&2
    exit 1
  fi
  echo "[hud-contract] ✅ ${desc}"
}

require_cmd curl
require_cmd jq
require_cmd agent-browser
require_cmd mix

cd "$REPO_ROOT/elixir"
mix forgeloop_v2.serve --repo .. --host "$HOST" --port "$PORT" >"$SERVICE_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 60); do
  if curl -fsS "$BASE_URL/api/schema" >/dev/null 2>&1; then
    break
  fi

  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[hud-contract] service exited unexpectedly" >&2
    tail -n 50 "$SERVICE_LOG" >&2 || true
    exit 1
  fi

  sleep 1
done

if ! curl -fsS "$BASE_URL/api/schema" >/dev/null 2>&1; then
  echo "[hud-contract] timed out waiting for $BASE_URL/api/schema" >&2
  tail -n 50 "$SERVICE_LOG" >&2 || true
  exit 1
fi

assert_json_value "schema exposes contract name" '/api/schema' '.data.contract_name' 'forgeloop_loopback'
assert_json_value "schema exposes contract version" '/api/schema' '.data.contract_version' '1'
assert_json_value "schema exposes overview path" '/api/schema' '.data.endpoints.overview.path' '/api/overview'
assert_json_value "overview envelope exposes api metadata" '/api/overview?limit=5' '.api.contract_version' '1'

agent-browser --session "$SESSION_NAME" open "$BASE_URL" >/dev/null 2>&1
agent-browser --session "$SESSION_NAME" wait "$BROWSER_WAIT_MS" >/dev/null 2>&1

assert_visible "connection pill renders" '#connection-pill'
assert_visible "control status renders" '#control-status'
assert_visible "runtime panel renders" '#runtime-body'
assert_visible "coordination panel renders" '#coordination-body'
assert_visible "events panel renders" '#events-body'
assert_text_contains "connection pill leaves boot state" '#connection-pill' 'Connected'

agent-browser --session "$SESSION_NAME" screenshot "$SCREENSHOT_PATH" >/dev/null 2>&1

echo "[hud-contract] ✅ screenshot saved to $SCREENSHOT_PATH"
echo "[hud-contract] PASS"
