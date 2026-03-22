#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: missing file: $path" >&2
    exit 1
  fi
}

wait_for_file() {
  local path="$1"
  local timeout_seconds="${2:-10}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if [[ -f "$path" ]]; then
      return 0
    fi
    sleep 0.1
  done

  assert_file_exists "$path"
}

prepare_repo_root_layout() {
  local target_root="$1"
  cp -R "$ROOT_DIR/bin" "$target_root/bin"
  cp -R "$ROOT_DIR/lib" "$target_root/lib"
  cp "$ROOT_DIR/config.sh" "$target_root/"
  cp -R "$ROOT_DIR/elixir" "$target_root/elixir"
  chmod +x "$target_root/bin/daemon.sh" "$target_root/bin/forgeloop-daemon.sh"
}

run_daemon_smoke() {
  local repo_dir="$1"
  local daemon_cmd="$2"
  local runtime_dir="$repo_dir/.forgeloop-smoke"
  local out_file="$runtime_dir/daemon.out"
  local shim_dir="$runtime_dir/shims"

  mkdir -p "$runtime_dir" "$shim_dir"
  printf '[PAUSE]\n' > "$repo_dir/REQUESTS.md"
  : > "$repo_dir/IMPLEMENTATION_PLAN.md"

  cat > "$shim_dir/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$shim_dir/flock"

  (
    cd "$repo_dir"
    PATH="$shim_dir:$PATH" \
    FORGELOOP_DAEMON_RUNTIME=elixir \
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
    FORGELOOP_DAEMON_LOCK_FILE="$runtime_dir/daemon.lock" \
    FORGELOOP_DAEMON_LOG_FILE="$runtime_dir/daemon.log" \
    bash -lc "$daemon_cmd"
  ) >"$out_file" 2>&1 &
  local pid=$!

  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$out_file" >&2
    echo "FAIL: daemon exited during bootstrap smoke test: $daemon_cmd" >&2
    exit 1
  fi

  wait_for_file "$runtime_dir/daemon.log"
  wait_for_file "$runtime_dir/v2/active-runtime.json"
  wait_for_file "$runtime_dir/runtime-state.json"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  assert_file_exists "$runtime_dir/daemon.log"
  assert_file_exists "$runtime_dir/v2/active-runtime.json"
  assert_file_exists "$runtime_dir/runtime-state.json"
}

tmp_root="$(mktemp -d)"
tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_target"' EXIT

prepare_repo_root_layout "$tmp_root"
run_daemon_smoke "$tmp_root" './bin/daemon.sh 1'

"$ROOT_DIR/install.sh" "$tmp_target" --force --wrapper >/dev/null
run_daemon_smoke "$tmp_target" './forgeloop.sh daemon 1'

echo "ok: daemon entrypoint layouts"
