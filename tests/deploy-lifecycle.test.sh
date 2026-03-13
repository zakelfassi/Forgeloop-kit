#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

mkdir -p "$tmp_repo/forgeloop/bin" "$tmp_repo/forgeloop/lib"
cp "$ROOT_DIR/bin/forgeloop-daemon.sh" "$tmp_repo/forgeloop/bin/"
cp "$ROOT_DIR/bin/escalate.sh" "$tmp_repo/forgeloop/bin/"
cp "$ROOT_DIR/config.sh" "$tmp_repo/forgeloop/"
cp "$ROOT_DIR/lib/core.sh" "$tmp_repo/forgeloop/lib/"
chmod +x "$tmp_repo/forgeloop/bin/forgeloop-daemon.sh" "$tmp_repo/forgeloop/bin/escalate.sh"

touch "$tmp_repo/REQUESTS.md" "$tmp_repo/IMPLEMENTATION_PLAN.md"

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_DAEMON_LOG_FILE="$tmp_repo/.forgeloop-test/daemon.log"
export FORGELOOP_DAEMON_LOCK_FILE="$tmp_repo/.forgeloop-test/daemon.lock"
export FORGELOOP_FAILURE_ESCALATE_AFTER=99

source "$tmp_repo/forgeloop/bin/forgeloop-daemon.sh"

order_file="$tmp_repo/deploy-order.txt"

export FORGELOOP_DEPLOY_PRE_CMD="printf 'pre\n' >> '$order_file'"
export FORGELOOP_DEPLOY_CMD="printf 'deploy\n' >> '$order_file'"
export FORGELOOP_DEPLOY_SMOKE_CMD="printf 'smoke\n' >> '$order_file'"

run_deploy

expected=$'pre\ndeploy\nsmoke'
actual="$(cat "$order_file")"
if [[ "$actual" != "$expected" ]]; then
  echo "FAIL: deploy lifecycle ran in unexpected order" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

rm -f "$order_file"
export FORGELOOP_DEPLOY_PRE_CMD="exit 7"
export FORGELOOP_DEPLOY_CMD="printf 'deploy\n' >> '$order_file'"
unset FORGELOOP_DEPLOY_SMOKE_CMD

if run_deploy; then
  echo "FAIL: run_deploy should fail when pre-deploy command fails" >&2
  exit 1
fi

if [[ -f "$order_file" ]]; then
  echo "FAIL: deploy command should not run after a pre-deploy failure" >&2
  exit 1
fi

echo "ok: deploy lifecycle"
