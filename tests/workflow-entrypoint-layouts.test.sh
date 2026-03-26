#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v mix >/dev/null 2>&1; then
  echo "skip: workflow entrypoint layouts (mix not available)"
  exit 0
fi

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected output to contain: $needle" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"

  if ! grep -Fq "$needle" "$file"; then
    echo "FAIL: expected $file to contain: $needle" >&2
    exit 1
  fi
}

prepare_repo_root_layout() {
  local target_root="$1"
  cp -R "$ROOT_DIR/bin" "$target_root/bin"
  cp -R "$ROOT_DIR/lib" "$target_root/lib"
  cp "$ROOT_DIR/config.sh" "$target_root/"
  cp -R "$ROOT_DIR/elixir" "$target_root/elixir"
  chmod +x "$target_root/bin/workflow.sh"
}

seed_workflow_fixture() {
  local repo_dir="$1"

  mkdir -p "$repo_dir/workflows/alpha" "$repo_dir/workflows/zeta" "$repo_dir/workflows/incomplete"
  printf 'digraph Alpha {}\n' > "$repo_dir/workflows/alpha/workflow.dot"
  printf 'version = 1\n' > "$repo_dir/workflows/alpha/workflow.toml"
  printf 'digraph Zeta {}\n' > "$repo_dir/workflows/zeta/workflow.dot"
  printf 'version = 1\n' > "$repo_dir/workflows/zeta/workflow.toml"
  printf 'digraph Incomplete {}\n' > "$repo_dir/workflows/incomplete/workflow.dot"
  printf '# done\n' > "$repo_dir/IMPLEMENTATION_PLAN.md"
  : > "$repo_dir/REQUESTS.md"
  : > "$repo_dir/QUESTIONS.md"
  : > "$repo_dir/ESCALATIONS.md"
  printf '.forgeloop-test/\n.workflow-runner.log\n.fake-bin/\n' > "$repo_dir/.gitignore"

  (
    cd "$repo_dir"
    git init -b main >/dev/null
    git config user.name 'Forgeloop Test' >/dev/null
    git config user.email 'forgeloop@example.com' >/dev/null
    git config commit.gpgsign false >/dev/null
    git config tag.gpgsign false >/dev/null
    git add . >/dev/null
    git commit -m 'workflow entrypoint fixture' >/dev/null
  )
}

run_workflow_entrypoint_smoke() {
  local repo_dir="$1"
  local bootstrap_cmd="$2"
  local workflow_cmd="$3"
  local runtime_dir="$repo_dir/.forgeloop-test"
  local fake_bin="$repo_dir/.fake-bin"
  local record_file="$repo_dir/.workflow-runner.log"

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

echo "ok:$mode:$workflow"
EOF
  chmod +x "$fake_bin/forgeloop-workflow"

  (
    cd "$repo_dir"
    PATH="$fake_bin:$PATH" \
    TEST_RECORD_FILE="$record_file" \
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
    bash -lc "$bootstrap_cmd"
  )

  (
    cd "$repo_dir"
    git add -A >/dev/null
    git commit --allow-empty -m 'workflow entrypoint bootstrap' >/dev/null
  )

  local list_output
  list_output="$(
    cd "$repo_dir"
    PATH="$fake_bin:$PATH" \
    TEST_RECORD_FILE="$record_file" \
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
    bash -lc "$workflow_cmd list"
  )"

  local expected_list=$'alpha\nzeta'
  if [[ "$list_output" != "$expected_list" ]]; then
    echo "FAIL: workflow list should be sorted and ignore incomplete packages" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected_list" "$list_output" >&2
    exit 1
  fi

  local preflight_output
  preflight_output="$(
    cd "$repo_dir"
    PATH="$fake_bin:$PATH" \
    TEST_RECORD_FILE="$record_file" \
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
    bash -lc "$workflow_cmd preflight alpha"
  )"

  assert_contains "$preflight_output" "ok:preflight:alpha"
  assert_file_contains "$record_file" "mode=preflight workflow=alpha"
  assert_file_contains "$record_file" "state_root=$runtime_dir/workflows/state"
  assert_file_contains "$record_file" "surface=workflow"
  assert_file_contains "$record_file" "runtime_mode=workflow-preflight"
  assert_file_contains "$record_file" "/.forgeloop-test/v2/workspaces/"
  assert_file_contains "$runtime_dir/workflows/alpha/last-preflight.txt" "ok:preflight:alpha"
  assert_file_contains "$runtime_dir/workflows/alpha/history.json" '"outcome": "succeeded"'
}

tmp_root="$(mktemp -d)"
tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_target"' EXIT

prepare_repo_root_layout "$tmp_root"
seed_workflow_fixture "$tmp_root"
run_workflow_entrypoint_smoke \
  "$tmp_root" \
  'cd elixir && mix deps.get >/dev/null && mix compile >/dev/null' \
  './bin/workflow.sh'

"$ROOT_DIR/install.sh" "$tmp_target" --force --wrapper >/dev/null
seed_workflow_fixture "$tmp_target"
run_workflow_entrypoint_smoke \
  "$tmp_target" \
  'cd forgeloop/elixir && mix deps.get >/dev/null && mix compile >/dev/null' \
  './forgeloop.sh workflow'

wrapper_help="$(cd "$tmp_target" && ./forgeloop.sh --help 2>&1)"
assert_contains "$wrapper_help" './forgeloop.sh workflow list'
assert_contains "$wrapper_help" './forgeloop.sh workflow preflight <name>'

echo "ok: workflow entrypoint layouts"
