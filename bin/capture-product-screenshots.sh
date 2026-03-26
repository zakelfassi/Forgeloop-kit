#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/lib/core.sh"

FIXTURE_DIR="${FORGELOOP_PRODUCT_SCREENSHOT_FIXTURE:-$REPO_ROOT/demo/signalboard}"
OUTPUT_DIR="${FORGELOOP_PRODUCT_SCREENSHOT_OUTPUT_DIR:-$REPO_ROOT/docs/assets/screenshots}"
ARTIFACT_DIR="${FORGELOOP_PRODUCT_SCREENSHOT_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/forgeloop-product-shots.XXXXXX")}" 
HOST="${FORGELOOP_PRODUCT_SCREENSHOT_HOST:-127.0.0.1}"
PORT="${FORGELOOP_PRODUCT_SCREENSHOT_PORT:-4048}"
BASE_URL="http://${HOST}:${PORT}"
SESSION_NAME="${FORGELOOP_PRODUCT_SCREENSHOT_SESSION:-forgeloop-product-shots}"
SERVICE_LOG="$ARTIFACT_DIR/service.log"
DEMO_REPO="$ARTIFACT_DIR/demo-repo"
OPERATOR_SHOT="$OUTPUT_DIR/forgeloop-operator-signalboard-demo.png"
DIRECTOR_SHOT="$OUTPUT_DIR/forgeloop-director-signalboard-demo.png"

usage() {
  cat <<'USAGE'
Usage:
  ./bin/capture-product-screenshots.sh
  ./bin/capture-product-screenshots.sh --help

Generate reproducible Forgeloop product screenshots from a seeded demo repo.

Defaults:
- fixture: demo/signalboard
- output: docs/assets/screenshots
- outputs:
  - forgeloop-operator-signalboard-demo.png
  - forgeloop-director-signalboard-demo.png
USAGE
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[product-shots] missing required command: $name" >&2
    exit 1
  fi
}

cleanup() {
  agent-browser --session "$SESSION_NAME" close >/dev/null 2>&1 || true
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_http() {
  local path="$1"
  local timeout_seconds="${2:-60}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl -fsS "$BASE_URL$path" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "${SERVER_PID:-}" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "[product-shots] service exited unexpectedly" >&2
      tail -n 60 "$SERVICE_LOG" >&2 || true
      exit 1
    fi
    sleep 0.25
  done

  echo "[product-shots] timed out waiting for $BASE_URL$path" >&2
  tail -n 60 "$SERVICE_LOG" >&2 || true
  exit 1
}

wait_for_visible() {
  local selector="$1"
  local timeout_seconds="${2:-20}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if agent-browser --session "$SESSION_NAME" is visible "$selector" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done

  echo "[product-shots] selector never became visible: $selector" >&2
  exit 1
}

wait_for_text() {
  local selector="$1"
  local expected="$2"
  local timeout_seconds="${3:-20}"
  local deadline=$((SECONDS + timeout_seconds))
  local text=""

  while (( SECONDS < deadline )); do
    text="$(agent-browser --session "$SESSION_NAME" get text "$selector" 2>/dev/null || true)"
    if printf '%s' "$text" | grep -Fqi -- "$expected"; then
      return 0
    fi
    sleep 0.25
  done

  echo "[product-shots] expected '$expected' in selector $selector, got: ${text:-<empty>}" >&2
  exit 1
}

case "${1:-}" in
  "" ) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "[product-shots] unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac

require_cmd agent-browser
require_cmd curl
require_cmd git
require_cmd mix
require_cmd rsync

[[ -d "$FIXTURE_DIR" ]] || { echo "[product-shots] missing fixture dir: $FIXTURE_DIR" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR" "$ARTIFACT_DIR"
rm -rf "$DEMO_REPO"
mkdir -p "$DEMO_REPO"
rsync -a "$FIXTURE_DIR/" "$DEMO_REPO/"
ln -s "$REPO_ROOT" "$DEMO_REPO/forgeloop"

(
  cd "$DEMO_REPO"
  git init -b main >/dev/null
  git config user.name 'Forgeloop Demo'
  git config user.email 'demo@forgeloop.local'
  git config commit.gpgsign false
  git add .
  git commit -m 'seed signalboard demo fixture' >/dev/null
)

(
  cd "$REPO_ROOT/elixir"
  mix deps.get >/dev/null
  mix compile >/dev/null
  mix forgeloop_v2.serve --repo "$DEMO_REPO" --host "$HOST" --port "$PORT" >"$SERVICE_LOG" 2>&1
) &
SERVER_PID=$!

wait_for_http '/api/schema' 60

agent-browser --session "$SESSION_NAME" open "$BASE_URL" >/dev/null
agent-browser --session "$SESSION_NAME" set viewport 1680 1280 >/dev/null
agent-browser --session "$SESSION_NAME" wait 1400 >/dev/null

wait_for_visible '#connection-pill'
wait_for_visible '#runtime-body'
wait_for_visible '#workflows-body'
wait_for_text '#director-showcase' 'What shipped'
agent-browser --session "$SESSION_NAME" screenshot "$OPERATOR_SHOT" >/dev/null

echo "[product-shots] operator screenshot: $OPERATOR_SHOT"

agent-browser --session "$SESSION_NAME" click '#scene-director' >/dev/null
wait_for_visible '#director-now'
agent-browser --session "$SESSION_NAME" click '#presentation-toggle' >/dev/null
wait_for_text '#presentation-toggle' 'Exit broadcast frame'
agent-browser --session "$SESSION_NAME" wait 1000 >/dev/null
agent-browser --session "$SESSION_NAME" screenshot "$DIRECTOR_SHOT" >/dev/null

echo "[product-shots] director screenshot: $DIRECTOR_SHOT"
echo "[product-shots] artifact dir: $ARTIFACT_DIR"
echo "[product-shots] PASS"
