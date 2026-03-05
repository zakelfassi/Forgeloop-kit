#!/usr/bin/env bash
# e2e.sh — browser-agent.dev e2e gate template for forgeloop projects
#
# Starts the dev server, runs agent-browser assertions, then tears down.
# Wire as FORGELOOP_VERIFY_CMD in forgeloop/config.sh:
#
#   export FORGELOOP_VERIFY_CMD="${FORGELOOP_VERIFY_CMD:-bash scripts/e2e.sh}"
#
# Exit 0 = pass (loop proceeds to commit/push)
# Exit 1 = fail (loop retries the build task with failure output as context)
#
# Requirements: npm install -g agent-browser
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${E2E_BASE_URL:-http://localhost:3000}"
PORT="${E2E_PORT:-3000}"

# Override the dev server start command for your stack:
#   Next.js:   pnpm dev
#   Vite:      pnpm dev --port $PORT
#   Rails:     bundle exec rails s -p $PORT
DEV_CMD="${E2E_DEV_CMD:-pnpm dev --port $PORT}"

DEV_PID=""

# ─── Teardown ────────────────────────────────────────────────────────────────
cleanup() {
  if [[ -n "$DEV_PID" ]] && kill -0 "$DEV_PID" 2>/dev/null; then
    echo "[e2e] Stopping dev server (pid $DEV_PID)..."
    kill "$DEV_PID" 2>/dev/null || true
    wait "$DEV_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ─── Skip if no frontend changes ─────────────────────────────────────────────
# Only run e2e when frontend files changed — skip for pure backend/docs iterations
CHANGED_FILES=$(git -C "$REPO_DIR" diff --name-only HEAD 2>/dev/null || git -C "$REPO_DIR" diff --name-only 2>/dev/null || echo "")
FRONTEND_CHANGED=$(echo "$CHANGED_FILES" | grep -E "^src/|^app/|^pages/|^public/|^components/|^index\.html" | head -1 || true)

if [[ -z "$FRONTEND_CHANGED" ]] && [[ "${E2E_FORCE:-false}" != "true" ]]; then
  echo "[e2e] No frontend changes detected — skipping browser e2e gate"
  exit 0
fi

# ─── Start dev server (skip if already running) ──────────────────────────────
if curl -sf "${BASE_URL}" >/dev/null 2>&1; then
  echo "[e2e] Dev server already running at ${BASE_URL}"
else
  echo "[e2e] Starting dev server: $DEV_CMD"
  cd "$REPO_DIR"
  bash -lc "$DEV_CMD" >/tmp/forgeloop-dev.log 2>&1 &
  DEV_PID=$!

  echo "[e2e] Waiting for port ${PORT}..."
  for i in $(seq 1 30); do
    if curl -sf "${BASE_URL}" >/dev/null 2>&1; then
      echo "[e2e] Server ready after ${i}s"
      break
    fi
    if ! kill -0 "$DEV_PID" 2>/dev/null; then
      echo "[e2e] Dev server died unexpectedly. Last output:"
      tail -20 /tmp/forgeloop-dev.log
      exit 1
    fi
    sleep 1
  done

  if ! curl -sf "${BASE_URL}" >/dev/null 2>&1; then
    echo "[e2e] Timeout: server not ready after 30s"
    exit 1
  fi
fi

# ─── Assertion helpers ────────────────────────────────────────────────────────
PASS=0
FAIL=0

assert_visible() {
  local desc="$1" selector="$2"
  if agent-browser is visible "$selector" >/dev/null 2>&1; then
    echo "[e2e] ✅  $desc"
    PASS=$((PASS + 1))
  else
    echo "[e2e] ❌  $desc (selector: $selector)"
    FAIL=$((FAIL + 1))
  fi
}

assert_text() {
  local desc="$1" selector="$2" pattern="$3"
  local text
  text=$(agent-browser get text "$selector" 2>/dev/null || echo "")
  if echo "$text" | grep -qi "$pattern"; then
    echo "[e2e] ✅  $desc"
    PASS=$((PASS + 1))
  else
    echo "[e2e] ❌  $desc (expected '$pattern', got: '${text:0:80}')"
    FAIL=$((FAIL + 1))
  fi
}

assert_api() {
  local desc="$1" path="$2" jq_filter="${3:-.}"
  local result
  result=$(curl -sf "${BASE_URL}${path}" 2>/dev/null | jq -r "$jq_filter" 2>/dev/null || echo "ERROR")
  if [[ "$result" != "ERROR" ]] && [[ -n "$result" ]]; then
    echo "[e2e] ✅  $desc"
    PASS=$((PASS + 1))
  else
    echo "[e2e] ❌  $desc (${path} → $result)"
    FAIL=$((FAIL + 1))
  fi
}

# ─── Tests — customise for your project ──────────────────────────────────────
echo "[e2e] Running assertions against ${BASE_URL}..."

agent-browser open "${BASE_URL}" >/dev/null 2>&1

# Core structure
assert_visible "Page title/heading visible"  "h1, h2"
assert_visible "Main content rendered"        "main, #root, #app, body > *"

# Screenshot for visual record
SCREENSHOT_DIR="${REPO_DIR}/.forgeloop/e2e-screenshots"
mkdir -p "$SCREENSHOT_DIR"
agent-browser screenshot "${SCREENSHOT_DIR}/$(date +%Y%m%d-%H%M%S).png" >/dev/null 2>&1 || true
echo "[e2e] 📸 Screenshot saved to .forgeloop/e2e-screenshots/"

agent-browser close >/dev/null 2>&1 || true

# ─── Add your project-specific assertions above this line ───────────────────
# Examples:
#   assert_visible "Login button"         "#login-btn"
#   assert_text    "Welcome heading"      "h1"           "Welcome"
#   assert_api     "/api/health"          "/api/health"  ".ok"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "[e2e] Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
  echo "[e2e] FAIL — blocking commit. Fix the above failures."
  exit 1
fi

echo "[e2e] PASS"
exit 0
