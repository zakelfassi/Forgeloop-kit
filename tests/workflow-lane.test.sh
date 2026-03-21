#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
fake_bin="$tmp_repo/.fake-bin"
record_file="$tmp_repo/.workflow-runner.log"
trap 'rm -rf "$tmp_repo"' EXIT

mkdir -p "$fake_bin"

cat > "$fake_bin/forgeloop-workflow" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "run" ]]; then
  echo "unexpected workflow runner command: $*" >&2
  exit 2
fi
shift

mode="run"
if [[ "${1:-}" == "--preflight" ]]; then
  mode="preflight"
  shift
fi

workflow="${1:-}"
shift || true

printf 'mode=%s workflow=%s state_root=%s surface=%s runtime_mode=%s pwd=%s extra=%s\n' \
  "$mode" \
  "$workflow" \
  "${FORGELOOP_WORKFLOW_STATE_ROOT:-}" \
  "${FORGELOOP_RUNTIME_SURFACE:-}" \
  "${FORGELOOP_RUNTIME_MODE:-}" \
  "$(pwd)" \
  "$*" >> "${TEST_RECORD_FILE:?}"

if [[ "$workflow" == "failing" ]]; then
  echo "simulated failure for $workflow"
  exit 1
fi

echo "ok:$mode:$workflow"
EOF
chmod +x "$fake_bin/forgeloop-workflow"

"$ROOT_DIR/install.sh" "$tmp_repo" --force --wrapper >/dev/null

mkdir -p "$tmp_repo/workflows/alpha" "$tmp_repo/workflows/zeta" "$tmp_repo/workflows/failing" "$tmp_repo/workflows/incomplete"
printf 'digraph Alpha {}\n' > "$tmp_repo/workflows/alpha/workflow.dot"
printf 'version = 1\n' > "$tmp_repo/workflows/alpha/workflow.toml"
printf 'digraph Zeta {}\n' > "$tmp_repo/workflows/zeta/workflow.dot"
printf 'version = 1\n' > "$tmp_repo/workflows/zeta/workflow.toml"
printf 'digraph Failing {}\n' > "$tmp_repo/workflows/failing/workflow.dot"
printf 'version = 1\n' > "$tmp_repo/workflows/failing/workflow.toml"
printf 'digraph Incomplete {}\n' > "$tmp_repo/workflows/incomplete/workflow.dot"
printf '.forgeloop-test/\n.workflow-runner.log\n' > "$tmp_repo/.gitignore"
(
  cd "$tmp_repo"
  git init -b main >/dev/null
  git config user.name 'Forgeloop Test' >/dev/null
  git config user.email 'forgeloop@example.com' >/dev/null
  git add . >/dev/null
  git commit -m 'workflow fixture' >/dev/null
)

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected output to contain [$needle]" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: expected $file to contain [$needle]" >&2
    exit 1
  fi
}

export PATH="$fake_bin:$PATH"
export TEST_RECORD_FILE="$record_file"
export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_FAILURE_ESCALATE_AFTER=1

list_output="$(cd "$tmp_repo" && ./forgeloop.sh workflow list)"
expected_list=$'alpha\nfailing\nzeta'
if [[ "$list_output" != "$expected_list" ]]; then
  echo "FAIL: workflow list should be sorted and unique" >&2
  printf 'expected:\n%s\nactual:\n%s\n' "$expected_list" "$list_output" >&2
  exit 1
fi
if grep -Fq "incomplete" <<<"$list_output"; then
  echo "FAIL: workflow list should ignore incomplete packages" >&2
  exit 1
fi

preflight_output="$(cd "$tmp_repo" && ./forgeloop.sh workflow preflight alpha)"
assert_contains "$preflight_output" "ok:preflight:alpha"
assert_file_contains "$record_file" "mode=preflight workflow=alpha"
assert_file_contains "$record_file" "state_root=$tmp_repo/.forgeloop-test/workflows/state"
assert_file_contains "$record_file" "surface=workflow"
assert_file_contains "$record_file" "runtime_mode=workflow-preflight"
assert_file_contains "$record_file" "/.forgeloop-test/v2/workspaces/"
assert_file_contains "$tmp_repo/.forgeloop-test/workflows/alpha/last-preflight.txt" "ok:preflight:alpha"

python3 - <<'PY' "$tmp_repo/.forgeloop-test/runtime-state.json"
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
assert data['status'] == 'idle', data
assert data['surface'] == 'workflow', data
assert data['mode'] == 'workflow-preflight', data
assert data['transition'] == 'completed', data
PY

run_output="$(cd "$tmp_repo" && ./forgeloop.sh workflow run zeta --no-retro)"
assert_contains "$run_output" "ok:run:zeta"
assert_file_contains "$tmp_repo/.forgeloop-test/workflows/zeta/last-run.txt" "ok:run:zeta"
assert_file_contains "$record_file" "mode=run workflow=zeta"
assert_file_contains "$record_file" "surface=workflow"
assert_file_contains "$record_file" "runtime_mode=workflow-run"
assert_file_contains "$record_file" "extra=--no-retro"

set +e
(cd "$tmp_repo" && ./forgeloop.sh workflow run failing) >/tmp/forgeloop-workflow-fail.out 2>&1
fail_status=$?
set -e
if [[ "$fail_status" -eq 0 ]]; then
  echo "FAIL: failing workflow should exit non-zero" >&2
  exit 1
fi

assert_file_contains "$tmp_repo/REQUESTS.md" "[PAUSE]"
assert_file_contains "$tmp_repo/QUESTIONS.md" "workflow-run"
assert_file_contains "$tmp_repo/ESCALATIONS.md" "workflow-run"

python3 - <<'PY' "$tmp_repo/.forgeloop-test/runtime-state.json"
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)
assert data['status'] == 'awaiting-human', data
assert data['surface'] == 'workflow', data
assert data['mode'] == 'workflow-run', data
assert data['transition'] == 'escalated', data
assert data['requested_action'] == 'review', data
PY

cp "$tmp_repo/REQUESTS.md" "$tmp_repo/REQUESTS.before-invalid"
cp "$tmp_repo/QUESTIONS.md" "$tmp_repo/QUESTIONS.before-invalid"
cp "$tmp_repo/ESCALATIONS.md" "$tmp_repo/ESCALATIONS.before-invalid"

set +e
(cd "$tmp_repo" && ./forgeloop.sh workflow run ../escape) >/tmp/forgeloop-workflow-invalid.out 2>&1
invalid_status=$?
set -e
if [[ "$invalid_status" -eq 0 ]]; then
  echo "FAIL: invalid workflow name should exit non-zero" >&2
  exit 1
fi

cmp -s "$tmp_repo/REQUESTS.md" "$tmp_repo/REQUESTS.before-invalid" || {
  echo "FAIL: invalid workflow name should not mutate REQUESTS.md" >&2
  exit 1
}
cmp -s "$tmp_repo/QUESTIONS.md" "$tmp_repo/QUESTIONS.before-invalid" || {
  echo "FAIL: invalid workflow name should not mutate QUESTIONS.md" >&2
  exit 1
}
cmp -s "$tmp_repo/ESCALATIONS.md" "$tmp_repo/ESCALATIONS.before-invalid" || {
  echo "FAIL: invalid workflow name should not mutate ESCALATIONS.md" >&2
  exit 1
}

echo "ok: workflow lane"
