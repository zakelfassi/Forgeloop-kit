#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

target_repo="$tmp_root/target-repo"
upgrade_src="$tmp_root/newer-kit"
mkdir -p "$target_repo"

"$ROOT_DIR/install.sh" "$target_repo" --force --wrapper >/dev/null

cp -R "$ROOT_DIR" "$upgrade_src"
printf '\nUPGRADE_MARKER_README\n' >> "$upgrade_src/README.md"
printf '\n# upgrade marker\n' >> "$upgrade_src/templates/AGENTS.md"
printf '\nUPGRADE_MARKER_INTAKE\n' >> "$upgrade_src/templates/PROMPT_intake.md"

"$target_repo/forgeloop.sh" upgrade --from "$upgrade_src" --force >/dev/null

if ! grep -q "UPGRADE_MARKER_README" "$target_repo/forgeloop/README.md"; then
    echo "FAIL: vendored kit was not refreshed from upgrade source" >&2
    exit 1
fi

if ! grep -q "# upgrade marker" "$target_repo/AGENTS.md"; then
    echo "FAIL: target repo templates were not reapplied during upgrade" >&2
    exit 1
fi

if ! grep -q "UPGRADE_MARKER_INTAKE" "$target_repo/PROMPT_intake.md"; then
    echo "FAIL: target repo PROMPT_intake.md was not reapplied during upgrade" >&2
    exit 1
fi

if [ ! -L "$target_repo/CLAUDE.md" ]; then
    echo "FAIL: upgraded target CLAUDE.md is not a symlink" >&2
    exit 1
fi

if [ "$(readlink "$target_repo/CLAUDE.md")" != "AGENTS.md" ]; then
    echo "FAIL: upgraded target CLAUDE.md points to $(readlink "$target_repo/CLAUDE.md")" >&2
    exit 1
fi

echo "ok: install upgrade"
