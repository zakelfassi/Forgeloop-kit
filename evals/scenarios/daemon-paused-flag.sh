#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tmp_repo="$(mktemp -d)"
daemon_pid=""
cleanup() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_repo"
}
trap cleanup EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null
printf '\n[PAUSE]\n' >> "$tmp_repo/REQUESTS.md"

state_file="$tmp_repo/.forgeloop-test/runtime-state.json"
shim_dir="$tmp_repo/.forgeloop-test/shims"
mkdir -p "$shim_dir"
cat > "$shim_dir/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$shim_dir/flock"

json_get() {
  local file="$1"
  local path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$path" "$file"
  else
    python3 - "$file" "$path" <<'PY'
import json
import sys

file_path, expr = sys.argv[1:]
with open(file_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
cur = data
for part in expr.lstrip(".").split("."):
    cur = cur[part]
print(cur)
PY
  fi
}

(
  cd "$tmp_repo"
  PATH="$shim_dir:$PATH" \
  FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test" \
  FORGELOOP_DAEMON_LOCK_FILE="$tmp_repo/.forgeloop-test/daemon.lock" \
  "$tmp_repo/forgeloop/bin/forgeloop-daemon.sh" 1
) >/dev/null 2>&1 &
daemon_pid=$!

for _ in $(seq 1 20); do
  if [[ -f "$state_file" ]] && [[ "$(json_get "$state_file" '.status')" == "paused" ]]; then
    break
  fi
  sleep 0.2
done

if [[ ! -f "$state_file" ]]; then
  echo "FAIL: daemon did not write runtime-state.json" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.status')" != "paused" ]]; then
  echo "FAIL: daemon should report paused state when [PAUSE] is present" >&2
  exit 1
fi

if [[ "$(json_get "$state_file" '.actor')" != "daemon" ]]; then
  echo "FAIL: daemon pause state should be attributed to daemon" >&2
  exit 1
fi

echo "ok: eval daemon-paused-flag"
