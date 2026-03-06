#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

fake_bin="$tmp_repo/.fake-bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/timeout" <<'EOF'
#!/usr/bin/env bash
log_file="${FORGELOOP_TIMEOUT_LOG:?}"
printf '%s\n' "$*" > "$log_file"
seconds="$1"
shift
"$@"
EOF

cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "codex-timeout-ok"
exit 0
EOF

chmod +x "$fake_bin/timeout" "$fake_bin/codex"

export PATH="$fake_bin:$PATH"
export FORGELOOP_TIMEOUT_LOG="$tmp_repo/timeout.log"
export FORGELOOP_LLM_TIMEOUT_SECONDS=42
export FORCE_MODEL=codex
export CODEX_FLAGS=""
export FORGELOOP_DISABLE_NOTIFICATIONS=true

source "$tmp_repo/forgeloop/lib/core.sh"
source "$tmp_repo/forgeloop/lib/llm.sh"

output="$(printf 'hello\n' | forgeloop_llm__exec "$tmp_repo" "stdin" "build" "" "$tmp_repo/llm.log")"

if [[ "$output" != *"codex-timeout-ok"* ]]; then
    echo "FAIL: Codex execution should still succeed through the timeout wrapper" >&2
    exit 1
fi

if [[ ! -f "$FORGELOOP_TIMEOUT_LOG" ]]; then
    echo "FAIL: timeout wrapper was not invoked" >&2
    exit 1
fi

if ! grep -q '^42 codex exec ' "$FORGELOOP_TIMEOUT_LOG"; then
    echo "FAIL: timeout wrapper should receive the configured timeout and codex command" >&2
    cat "$FORGELOOP_TIMEOUT_LOG" >&2
    exit 1
fi

echo "ok: llm timeout wrapper"
