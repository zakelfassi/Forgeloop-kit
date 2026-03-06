#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

fake_bin="$tmp_repo/.fake-bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "Invalid API Key"
exit 0
EOF

cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "codex-fallback-ok"
exit 0
EOF

chmod +x "$fake_bin/claude" "$fake_bin/codex"

export PATH="$fake_bin:$PATH"
export ENABLE_FAILOVER=true
export BUILD_MODEL=claude
export REVIEW_MODEL=claude
export SECURITY_MODEL=claude
export TASK_ROUTING=false
export CLAUDE_FLAGS=""
export CODEX_FLAGS=""
export FORGELOOP_DISABLE_NOTIFICATIONS=true

source "$tmp_repo/forgeloop/lib/core.sh"
source "$tmp_repo/forgeloop/lib/llm.sh"

log_file="$tmp_repo/llm.log"
output="$(printf 'hello\n' | forgeloop_llm__exec "$tmp_repo" "stdin" "build" "" "$log_file")"

if [[ "$output" != *"codex-fallback-ok"* ]]; then
    echo "FAIL: auth-pattern output with exit 0 should fail over to Codex" >&2
    exit 1
fi

if ! grep -q 'Failing over to Codex due to Claude auth failure' "$log_file"; then
    echo "FAIL: auth-pattern output should be treated as an auth failure even with exit 0" >&2
    exit 1
fi

echo "ok: llm auth failover"
