#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$ROOT_DIR/lib/core.sh"

if ! forgeloop_core__looks_like_deploy_cmd "sudo systemctl restart zaigood"; then
  echo "FAIL: systemctl restart should be treated as deploy-like" >&2
  exit 1
fi

if ! forgeloop_core__looks_like_deploy_cmd "kubectl rollout restart deployment/api"; then
  echo "FAIL: kubectl rollout should be treated as deploy-like" >&2
  exit 1
fi

if forgeloop_core__looks_like_deploy_cmd "npm test && npm run build"; then
  echo "FAIL: plain validation command should not be treated as deploy-like" >&2
  exit 1
fi

export FORGELOOP_VERIFY_BLOCK_DEPLOY_LIKE_CMD=true

if message=$(forgeloop_core__validate_verify_cmd "sudo systemctl restart zaigood"); then
  echo "FAIL: deploy-like verify command should be rejected" >&2
  exit 1
fi

if [[ "$message" != *"FORGELOOP_DEPLOY_PRE_CMD"* ]]; then
  echo "FAIL: rejection message should point to deploy lifecycle hooks" >&2
  exit 1
fi

if ! forgeloop_core__validate_verify_cmd "npm test && npm run build" >/dev/null; then
  echo "FAIL: validation-only verify command should pass" >&2
  exit 1
fi

echo "ok: verify command safety"
