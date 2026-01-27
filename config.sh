#!/usr/bin/env bash
set -euo pipefail

# Forgeloop Framework Config
# - This file is safe to commit.
# - Override any value by exporting it before running Forgeloop.

# Runtime dir (relative to repo root if not absolute)
export FORGELOOP_RUNTIME_DIR="${FORGELOOP_RUNTIME_DIR:-.forgeloop}"

# Git defaults
export FORGELOOP_DEFAULT_BRANCH="${FORGELOOP_DEFAULT_BRANCH:-main}"
export FORGELOOP_GIT_REMOTE="${FORGELOOP_GIT_REMOTE:-origin}"

# If true, Forgeloop will try to push after each loop iteration.
# Safe default is false for new repos; enable on a dedicated branch/runner.
export FORGELOOP_AUTOPUSH="${FORGELOOP_AUTOPUSH:-false}"

# If true, plan/plan-work modes will push after each iteration (no CI gate).
export FORGELOOP_PLAN_AUTOPUSH="${FORGELOOP_PLAN_AUTOPUSH:-false}"

# Prompt files (relative to repo root)
export FORGELOOP_PROMPT_PLAN="${FORGELOOP_PROMPT_PLAN:-PROMPT_plan.md}"
export FORGELOOP_PROMPT_BUILD="${FORGELOOP_PROMPT_BUILD:-PROMPT_build.md}"
export FORGELOOP_PROMPT_PLAN_WORK="${FORGELOOP_PROMPT_PLAN_WORK:-PROMPT_plan_work.md}"

# Forgeloop coordination files (relative to repo root)
export FORGELOOP_IMPLEMENTATION_PLAN_FILE="${FORGELOOP_IMPLEMENTATION_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
export FORGELOOP_STATUS_FILE="${FORGELOOP_STATUS_FILE:-STATUS.md}"
export FORGELOOP_REQUESTS_FILE="${FORGELOOP_REQUESTS_FILE:-REQUESTS.md}"
export FORGELOOP_QUESTIONS_FILE="${FORGELOOP_QUESTIONS_FILE:-QUESTIONS.md}"
export FORGELOOP_CHANGELOG_FILE="${FORGELOOP_CHANGELOG_FILE:-CHANGELOG.md}"

# Optional: command to run after Codex review auto-fixes (e.g. "pnpm test:ci", "npm test", "pytest -q")
export FORGELOOP_TEST_CMD="${FORGELOOP_TEST_CMD:-}"

# Optional: verification command run before CI gate/push (loop.sh) or per-task (loop-tasks.sh)
export FORGELOOP_VERIFY_CMD="${FORGELOOP_VERIFY_CMD:-}"

# If true, prd.json may provide per-task or global `verify_cmd` (tasks lane).
export FORGELOOP_ALLOW_PRD_VERIFY_CMD="${FORGELOOP_ALLOW_PRD_VERIFY_CMD:-false}"

# Max diff size to send into review/security gates (chars)
export FORGELOOP_MAX_DIFF_CHARS="${FORGELOOP_MAX_DIFF_CHARS:-120000}"

# Max chars for untrusted context injection (CI/verify outputs)
export FORGELOOP_UNTRUSTED_CONTEXT_MAX_CHARS="${FORGELOOP_UNTRUSTED_CONTEXT_MAX_CHARS:-20000}"

# Optional: CI gate command to run before pushing to protected branches (main/master).
# Auto-detected during installation based on project type. Examples:
#   Node.js: "pnpm typecheck && pnpm lint && pnpm test && pnpm build"
#   Rust:    "cargo check && cargo test && cargo build --release"
#   Go:      "go vet ./... && go test ./... && go build ./..."
#   Python:  "pytest && mypy ."
#   Swift:   "swift build && swift test"
# Leave empty to skip CI gating.
export FORGELOOP_CI_GATE_CMD="${FORGELOOP_CI_GATE_CMD:-}"

# Optional: deploy command the daemon runs when it sees [DEPLOY] in REQUESTS.md
export FORGELOOP_DEPLOY_CMD="${FORGELOOP_DEPLOY_CMD:-}"

# Optional: when true, ingestion scripts append a [REPLAN] trigger after adding a request
export FORGELOOP_INGEST_TRIGGER_REPLAN="${FORGELOOP_INGEST_TRIGGER_REPLAN:-false}"

# Log ingestion (ingest-logs.sh)
export FORGELOOP_LOGS_DIR="${FORGELOOP_LOGS_DIR:-logs}"
export FORGELOOP_INGEST_LOGS_CMD="${FORGELOOP_INGEST_LOGS_CMD:-}"
export FORGELOOP_INGEST_LOGS_FILE="${FORGELOOP_INGEST_LOGS_FILE:-}"
export FORGELOOP_INGEST_LOGS_TAIL="${FORGELOOP_INGEST_LOGS_TAIL:-400}"
export FORGELOOP_INGEST_LOGS_MAX_CHARS="${FORGELOOP_INGEST_LOGS_MAX_CHARS:-60000}"

# Optional: auto-ingest logs after deploy in daemon mode (use with care)
export FORGELOOP_POST_DEPLOY_INGEST_LOGS="${FORGELOOP_POST_DEPLOY_INGEST_LOGS:-false}"
export FORGELOOP_POST_DEPLOY_OBSERVE_SECONDS="${FORGELOOP_POST_DEPLOY_OBSERVE_SECONDS:-0}"
