#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

target_repo="$tmp_root/target-repo"
mkdir -p "$target_repo"

cat > "$target_repo/AGENTS.md" <<'EOF'
# existing agents
EOF

cat > "$target_repo/CLAUDE.md" <<'EOF'
# Project Operational Guide (Claude)

Claude Code uses this file as project instructions.

Start by reading `AGENTS.md`, `specs/`, and `docs/`.
EOF

"$ROOT_DIR/install.sh" "$target_repo" >/dev/null

if [ ! -L "$target_repo/CLAUDE.md" ]; then
    echo "FAIL: migrated target CLAUDE.md is not a symlink" >&2
    exit 1
fi

if [ "$(readlink "$target_repo/CLAUDE.md")" != "AGENTS.md" ]; then
    echo "FAIL: migrated target CLAUDE.md points to $(readlink "$target_repo/CLAUDE.md")" >&2
    exit 1
fi

echo "ok: install claude symlink migration"
