#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Generate a kickoff prompt for a memory-backed agent to author docs/specs for a greenfield repo.

Usage:
  ./forgeloop/bin/kickoff.sh "<project brief>" [--project <name>] [--seed <path-or-url>] [--notes <text>] [--out <path>]

Examples:
  ./forgeloop/bin/kickoff.sh "A private, project-scoped stories app" --project gablus
  ./forgeloop/bin/kickoff.sh "CLI to sync Notion docs to MD" --seed https://github.com/acme/old-repo

Notes:
- This writes a file you paste into a memory-backed agent (ChatGPT Projects, Claude Projects, etc.).
- Output is markdown only (no code changes).
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"
REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  usage
  exit 1
fi

PROJECT_BRIEF="$1"
shift

PROJECT_NAME="$(basename "$REPO_DIR")"
SEED_SOURCE=""
EXTRA_NOTES=""
OUT_PATH="$REPO_DIR/docs/KICKOFF_PROMPT.md"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --project)
      PROJECT_NAME="${2:-}"
      shift 2
      ;;
    --seed)
      SEED_SOURCE="${2:-}"
      shift 2
      ;;
    --notes)
      EXTRA_NOTES="${2:-}"
      shift 2
      ;;
    --out)
      OUT_PATH="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname "$OUT_PATH")"

cat > "$OUT_PATH" <<FORGELOOP_KICKOFF_PROMPT
# Kickoff Prompt (Memory-Backed Requirements Agent)

You are a senior product+engineering spec writer.

You have access to long-term memory / prior project context (if available). Use it to write high-signal docs/specs for a NEW repository that will be built using a Forgeloop-style loop.

## Project
- Name: $PROJECT_NAME
- Brief: $PROJECT_BRIEF
FORGELOOP_KICKOFF_PROMPT

if [ -n "$SEED_SOURCE" ]; then
  cat >> "$OUT_PATH" <<FORGELOOP_KICKOFF_PROMPT
- Seed source (optional): $SEED_SOURCE
FORGELOOP_KICKOFF_PROMPT
fi

if [ -n "$EXTRA_NOTES" ]; then
  cat >> "$OUT_PATH" <<FORGELOOP_KICKOFF_PROMPT
- Notes: $EXTRA_NOTES
FORGELOOP_KICKOFF_PROMPT
fi

cat >> "$OUT_PATH" <<'FORGELOOP_KICKOFF_PROMPT'

## Your job
Create/overwrite the project’s documentation and specifications so that a coding agent can plan + build deterministically.

### Files to write (markdown only)
Return a **unified diff / git patch** that creates or updates ONLY these markdown files:

- `AGENTS.md` (operational guide)
- `docs/README.md` (index)
- `docs/01_PRD.md` (what/why, users, scope)
- `docs/02_ARCHITECTURE.md` (high-level architecture; keep it simple)
- `specs/` (one file per topic of concern; use acceptance criteria)
- `IMPLEMENTATION_PLAN.md` (prioritized checklist)

If some of these already exist, update them. Keep everything concise and high-signal.

### Spec requirements
Each `specs/*.md` should include:
- Summary + user stories
- Functional requirements
- Edge cases
- Acceptance criteria as **observable outcomes** (WHAT to verify, not HOW to implement)

### Plan requirements
`IMPLEMENTATION_PLAN.md` should be a prioritized checklist:
- Each item must include **REQUIRED TESTS** derived from acceptance criteria
- Keep items small (1–2 days max each)
- If uncertain about scope, ask questions first

## Constraints
- Markdown only. Do NOT implement code.
- Ask up to 10 clarifying questions first if needed, then proceed.
- Prefer 3–8 high-quality spec files over many vague ones.

## Output format
Return a single patch in a code block (unified diff) that the user can apply with `git apply`.
FORGELOOP_KICKOFF_PROMPT

echo "Wrote kickoff prompt: $OUT_PATH"
