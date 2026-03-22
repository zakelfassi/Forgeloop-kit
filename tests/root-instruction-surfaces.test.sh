#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_FILE="$ROOT_DIR/AGENTS.md"
CLAUDE_FILE="$ROOT_DIR/CLAUDE.md"

fail() {
  echo "root-instruction-surfaces: $*" >&2
  exit 1
}

[[ -f "$AGENTS_FILE" ]] || fail "missing root AGENTS.md"
[[ -L "$CLAUDE_FILE" ]] || fail "CLAUDE.md is not a symlink"
[[ "$(readlink "$CLAUDE_FILE")" == "AGENTS.md" ]] || fail "CLAUDE.md points to $(readlink "$CLAUDE_FILE") instead of AGENTS.md"

grep -Fq 'bash tests/run.sh' "$AGENTS_FILE" || fail "AGENTS.md missing bash tests/run.sh"
grep -Fq 'bash evals/run.sh' "$AGENTS_FILE" || fail "AGENTS.md missing bash evals/run.sh"
grep -Fq 'cd elixir && mix test' "$AGENTS_FILE" || fail "AGENTS.md missing cd elixir && mix test"
grep -Fq 'docs/runtime-control.md' "$AGENTS_FILE" || fail "AGENTS.md missing docs/runtime-control.md"
grep -Fq 'docs/harness-readiness.md' "$AGENTS_FILE" || fail "AGENTS.md missing docs/harness-readiness.md"
grep -Fq 'templates/' "$AGENTS_FILE" || fail "AGENTS.md missing templates/ anchor"
grep -Fq '.openclaw/' "$AGENTS_FILE" || fail "AGENTS.md missing .openclaw/ anchor"

echo "root instruction surfaces ok"
