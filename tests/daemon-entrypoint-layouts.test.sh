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

run_daemon_smoke() {
  local repo_dir="$1"
  local daemon_script="$2"
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

  PATH="$shim_dir:$PATH" \
  FORGELOOP_RUNTIME_DIR="$runtime_dir" \
  FORGELOOP_DAEMON_LOCK_FILE="$runtime_dir/daemon.lock" \
  FORGELOOP_DAEMON_LOG_FILE="$runtime_dir/daemon.log" \
  bash "$daemon_script" 1 >"$out_file" 2>&1 &
  local pid=$!

  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$out_file" >&2
    echo "FAIL: daemon exited during bootstrap smoke test: $daemon_script" >&2
    exit 1
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_file_exists "$runtime_dir/daemon.log"
}

tmp_root="$(mktemp -d)"
tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_target"' EXIT

mkdir -p "$tmp_root/bin" "$tmp_root/lib"
cp "$ROOT_DIR/bin/forgeloop-daemon.sh" "$tmp_root/bin/"
cp "$ROOT_DIR/config.sh" "$tmp_root/"
cp "$ROOT_DIR/lib/core.sh" "$tmp_root/lib/"
chmod +x "$tmp_root/bin/forgeloop-daemon.sh"

run_daemon_smoke "$tmp_root" "$tmp_root/bin/forgeloop-daemon.sh"

"$ROOT_DIR/install.sh" "$tmp_target" --force >/dev/null
run_daemon_smoke "$tmp_target" "$tmp_target/forgeloop/bin/forgeloop-daemon.sh"

echo "ok: daemon entrypoint layouts"
