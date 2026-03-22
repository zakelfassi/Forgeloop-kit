#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$KIT_ROOT_DEFAULT/lib/core.sh"

DEFAULT_REPO_ROOT="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
DEFAULT_FORGELOOP_ROOT="$(forgeloop_core__resolve_forgeloop_dir "$DEFAULT_REPO_ROOT")"

REPO_ROOT="${FORGELOOP_SELF_HOST_PROOF_REPO_ROOT:-${FORGELOOP_E2E_REPO_ROOT:-$DEFAULT_REPO_ROOT}}"
FORGELOOP_ROOT="${FORGELOOP_SELF_HOST_PROOF_FORGELOOP_ROOT:-${FORGELOOP_E2E_FORGELOOP_ROOT:-$DEFAULT_FORGELOOP_ROOT}}"
HOST="${FORGELOOP_SELF_HOST_PROOF_HOST:-${FORGELOOP_E2E_HOST:-127.0.0.1}}"
PORT="${FORGELOOP_SELF_HOST_PROOF_PORT:-${FORGELOOP_E2E_PORT:-4047}}"
BASE_URL="http://${HOST}:${PORT}"
DEFAULT_ARTIFACT_BASE="$REPO_ROOT/.forgeloop/self-host-proof"
mkdir -p "$DEFAULT_ARTIFACT_BASE"
ARTIFACT_DIR="${FORGELOOP_SELF_HOST_PROOF_ARTIFACT_DIR:-${FORGELOOP_E2E_LOG_DIR:-$(mktemp -d "$DEFAULT_ARTIFACT_BASE/run-XXXXXX")}}"
SESSION_NAME="${FORGELOOP_SELF_HOST_PROOF_SESSION:-${FORGELOOP_E2E_SESSION:-forgeloop-self-host-proof}}"
BROWSER_WAIT_MS="${FORGELOOP_SELF_HOST_PROOF_WAIT_MS:-${FORGELOOP_E2E_WAIT_MS:-1200}}"
SCREENSHOT_PATH="${FORGELOOP_SELF_HOST_PROOF_SCREENSHOT:-${FORGELOOP_E2E_SCREENSHOT:-$ARTIFACT_DIR/$(date +%Y%m%d-%H%M%S)-self-host-proof.png}}"
SERVICE_LOG="${FORGELOOP_SELF_HOST_PROOF_SERVICE_LOG:-$ARTIFACT_DIR/service.log}"
PLAN_SOURCE="${FORGELOOP_SELF_HOST_PROOF_PLAN_SOURCE:-$REPO_ROOT/IMPLEMENTATION_PLAN.md}"

export FORGELOOP_SHELL_DRIVER_ENABLED="${FORGELOOP_SHELL_DRIVER_ENABLED:-false}"
export FORGELOOP_RUNTIME_DIR="${FORGELOOP_RUNTIME_DIR:-$ARTIFACT_DIR/runtime}"
export FORGELOOP_REQUESTS_FILE="${FORGELOOP_REQUESTS_FILE:-$ARTIFACT_DIR/control/REQUESTS.md}"
export FORGELOOP_QUESTIONS_FILE="${FORGELOOP_QUESTIONS_FILE:-$ARTIFACT_DIR/control/QUESTIONS.md}"
export FORGELOOP_ESCALATIONS_FILE="${FORGELOOP_ESCALATIONS_FILE:-$ARTIFACT_DIR/control/ESCALATIONS.md}"
export FORGELOOP_IMPLEMENTATION_PLAN_FILE="${FORGELOOP_IMPLEMENTATION_PLAN_FILE:-$ARTIFACT_DIR/control/IMPLEMENTATION_PLAN.md}"

mkdir -p "$ARTIFACT_DIR" "$(dirname "$SCREENSHOT_PATH")" "$(dirname "$SERVICE_LOG")"

print_artifacts() {
  echo "[self-host-proof] artifact dir: $ARTIFACT_DIR"
  echo "[self-host-proof] screenshot: $SCREENSHOT_PATH"
  echo "[self-host-proof] service log: $SERVICE_LOG"
}

cleanup() {
  agent-browser --session "$SESSION_NAME" screenshot "$SCREENSHOT_PATH" >/dev/null 2>&1 || true
  agent-browser --session "$SESSION_NAME" close >/dev/null 2>&1 || true

  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() {
  local message="$1"
  echo "[self-host-proof] ${message}" >&2
  if [[ -f "$SERVICE_LOG" ]]; then
    echo "[self-host-proof] --- service log tail ---" >&2
    tail -n 60 "$SERVICE_LOG" >&2 || true
  fi
  print_artifacts >&2
  exit 1
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    fail "missing required command: $name"
  fi
}

prepare_proof_inputs() {
  mkdir -p \
    "$FORGELOOP_RUNTIME_DIR" \
    "$(dirname "$FORGELOOP_REQUESTS_FILE")" \
    "$(dirname "$FORGELOOP_QUESTIONS_FILE")" \
    "$(dirname "$FORGELOOP_ESCALATIONS_FILE")" \
    "$(dirname "$FORGELOOP_IMPLEMENTATION_PLAN_FILE")"

  : > "$FORGELOOP_REQUESTS_FILE"
  : > "$FORGELOOP_QUESTIONS_FILE"
  : > "$FORGELOOP_ESCALATIONS_FILE"

  if [[ -f "$PLAN_SOURCE" ]]; then
    cp "$PLAN_SOURCE" "$FORGELOOP_IMPLEMENTATION_PLAN_FILE"
  else
    cat > "$FORGELOOP_IMPLEMENTATION_PLAN_FILE" <<'EOF'
# Implementation Plan

## Backlog

- [ ] Pending item
EOF
  fi
}

check_server_alive() {
  if [[ -n "${SERVER_PID:-}" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    fail "service exited unexpectedly"
  fi
}

wait_for_http() {
  local path="$1"
  local timeout_seconds="${2:-60}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl -fsS "$BASE_URL$path" >/dev/null 2>&1; then
      return 0
    fi
    check_server_alive
    sleep 0.25
  done

  fail "timed out waiting for $BASE_URL$path"
}

wait_for_json_expr() {
  local desc="$1"
  local path="$2"
  local filter="$3"
  local timeout_seconds="${4:-30}"
  local deadline=$((SECONDS + timeout_seconds))
  local payload=""

  while (( SECONDS < deadline )); do
    if payload="$(curl -fsS "$BASE_URL$path" 2>/dev/null || true)"; then
      if [[ -n "$payload" ]] && jq -e "$filter" >/dev/null <<<"$payload" 2>/dev/null; then
        echo "[self-host-proof] ✅ ${desc}"
        return 0
      fi
    fi
    check_server_alive
    sleep 0.25
  done

  echo "[self-host-proof] last payload for ${path}: ${payload:-<empty>}" >&2
  fail "${desc} failed: jq filter was false: $filter"
}

assert_json_expr() {
  local desc="$1"
  local path="$2"
  local filter="$3"
  local payload

  payload="$(curl -fsS "$BASE_URL$path")"
  if ! jq -e "$filter" >/dev/null <<<"$payload"; then
    echo "[self-host-proof] last payload for ${path}: ${payload:-<empty>}" >&2
    fail "${desc} failed: jq filter was false: $filter"
  fi
  echo "[self-host-proof] ✅ ${desc}"
}

assert_json_value() {
  local desc="$1"
  local path="$2"
  local filter="$3"
  local expected="$4"
  local actual

  actual="$(curl -fsS "$BASE_URL$path" | jq -r "$filter")"
  if [[ "$actual" != "$expected" ]]; then
    fail "${desc} failed: expected '$expected', got '$actual'"
  fi
  echo "[self-host-proof] ✅ ${desc}"
}

wait_for_visible() {
  local desc="$1"
  local selector="$2"
  local timeout_seconds="${3:-20}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if agent-browser --session "$SESSION_NAME" is visible "$selector" >/dev/null 2>&1; then
      echo "[self-host-proof] ✅ ${desc}"
      return 0
    fi
    sleep 0.25
  done

  fail "${desc} failed: selector not visible: $selector"
}

wait_for_text_contains() {
  local desc="$1"
  local selector="$2"
  local expected="$3"
  local timeout_seconds="${4:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  local text=""

  while (( SECONDS < deadline )); do
    text="$(agent-browser --session "$SESSION_NAME" get text "$selector" 2>/dev/null || true)"
    if printf '%s' "$text" | grep -Fqi -- "$expected"; then
      echo "[self-host-proof] ✅ ${desc}"
      return 0
    fi
    sleep 0.25
  done

  fail "${desc} failed: expected '$expected' in '$text'"
}

click_selector() {
  local desc="$1"
  local selector="$2"
  if ! agent-browser --session "$SESSION_NAME" click "$selector" >/dev/null 2>&1; then
    fail "${desc} failed: could not click $selector"
  fi
  echo "[self-host-proof] ✅ ${desc}"
}

assert_empty_file() {
  local desc="$1"
  local path="$2"
  if [[ -s "$path" ]]; then
    echo "[self-host-proof] file contents for ${path}:" >&2
    cat "$path" >&2 || true
    fail "${desc} failed: expected empty file"
  fi
  echo "[self-host-proof] ✅ ${desc}"
}

require_cmd curl
require_cmd jq
require_cmd agent-browser
require_cmd mix

prepare_proof_inputs

(
  cd "$FORGELOOP_ROOT/elixir"
  mix forgeloop_v2.serve --repo "$REPO_ROOT" --host "$HOST" --port "$PORT" >"$SERVICE_LOG" 2>&1
) &
SERVER_PID=$!

wait_for_http '/api/schema' 60

assert_json_value "schema exposes contract name" '/api/schema' '.data.contract_name' 'forgeloop_loopback'
assert_json_value "schema exposes contract version" '/api/schema' '.data.contract_version' '1'
assert_json_value "schema exposes overview path" '/api/schema' '.data.endpoints.overview.path' '/api/overview'
assert_json_value "overview envelope exposes api metadata" '/api/overview?limit=5' '.api.contract_version' '1'
wait_for_json_expr "overview starts ownership in ready state" '/api/overview?limit=5' '.data.ownership.summary_state == "ready"'
wait_for_json_expr "overview starts with allowed start gate" '/api/overview?limit=5' '.data.ownership.start_gate.status == "allowed"'

agent-browser --session "$SESSION_NAME" open "$BASE_URL" >/dev/null 2>&1
agent-browser --session "$SESSION_NAME" wait "$BROWSER_WAIT_MS" >/dev/null 2>&1

wait_for_visible "connection pill renders" '#connection-pill'
wait_for_visible "control status renders" '#control-status'
wait_for_visible "runtime panel renders" '#runtime-body'
wait_for_visible "ownership panel renders" '#ownership-body'
wait_for_visible "coordination panel renders" '#coordination-body'
wait_for_visible "events panel renders" '#events-body'
wait_for_text_contains "connection pill leaves boot state" '#connection-pill' 'connected'
wait_for_text_contains "ownership panel leaves empty state" '#ownership-body' 'start gate'

click_selector "pause button responds" '#control-pause'
wait_for_text_contains "pause notice renders" '#control-status' 'Pause requested.'
wait_for_json_expr "overview shows pause requested" '/api/overview?limit=5' '.data.control_flags["pause_requested?"] == true'
wait_for_json_expr "overview runtime enters paused state" '/api/overview?limit=5' '.data.runtime_state.status == "paused"'

click_selector "clear-pause button responds" '#control-clear-pause'
wait_for_text_contains "clear-pause notice renders" '#control-status' 'Pause cleared.'
wait_for_json_expr "overview clears pause flag" '/api/overview?limit=5' '.data.control_flags["pause_requested?"] == false'
wait_for_json_expr "clear pause preserves paused runtime state" '/api/overview?limit=5' '.data.runtime_state.status == "paused"'

click_selector "replan button responds" '#control-replan'
wait_for_text_contains "replan notice renders" '#control-status' 'Replan requested.'
wait_for_json_expr "overview shows replan requested" '/api/overview?limit=5' '.data.control_flags["replan_requested?"] == true'

click_selector "run-plan button responds" '#control-run-plan'
wait_for_text_contains "run-plan notice renders" '#control-status' 'plan run launched via UI surface.'
wait_for_json_expr "events API records UI start_run action" '/api/events?limit=20' 'any(.data[]; .event_code == "operator_action" and .action == "start_run" and .runtime_surface == "ui" and .mode == "plan")'
wait_for_text_contains "events panel reflects start_run" '#events-body' 'start_run'
assert_empty_file "questions file stays empty after noop proof run" "$FORGELOOP_QUESTIONS_FILE"
assert_empty_file "escalations file stays empty after noop proof run" "$FORGELOOP_ESCALATIONS_FILE"

agent-browser --session "$SESSION_NAME" screenshot "$SCREENSHOT_PATH" >/dev/null 2>&1

echo "[self-host-proof] ✅ screenshot saved to $SCREENSHOT_PATH"
print_artifacts
echo "[self-host-proof] PASS"
