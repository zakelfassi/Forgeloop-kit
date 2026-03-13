#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

source "$tmp_repo/forgeloop/lib/core.sh"

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"

mkdir -p "$FORGELOOP_RUNTIME_DIR/logs"
chmod 0777 "$FORGELOOP_RUNTIME_DIR" "$FORGELOOP_RUNTIME_DIR/logs"

runtime_dir="$(forgeloop_core__ensure_runtime_dirs "$tmp_repo")"
state_file="$(forgeloop_core__runtime_state_file "$tmp_repo")"

forgeloop_core__set_runtime_state "$tmp_repo" "running" "loop" "build" "Bootstrapping runtime" "started" "" "main"
chmod 0666 "$state_file"
forgeloop_core__set_runtime_state "$tmp_repo" "idle" "loop" "build" "Runtime finished cleanly" "completed" "" "main"

python3 - <<'PY' "$runtime_dir" "$runtime_dir/logs" "$state_file"
import os
import stat
import sys

expected = {
    sys.argv[1]: 0o700,
    sys.argv[2]: 0o700,
    sys.argv[3]: 0o600,
}

for path, want in expected.items():
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == want, (path, oct(mode), oct(want))
PY

echo "ok: runtime permissions"
