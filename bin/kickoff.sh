#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Render a reusable Forgeloop intake prompt for a memory-backed agent or external LLM.

Usage:
  ./forgeloop/bin/kickoff.sh "<project brief>" [--project <name>] [--seed <path-or-url>] [--notes <text>] [--out <path>]

Examples:
  ./forgeloop/bin/kickoff.sh "A private, project-scoped stories app" --project gablus
  ./forgeloop/bin/kickoff.sh "CLI to sync Notion docs to MD" --seed https://github.com/acme/old-repo

Notes:
- This renders a shareable markdown prompt from repo-local `PROMPT_intake.md` when available.
- Output is markdown only (no code changes).
USAGE
}

resolve_prompt_source() {
  local repo_prompt="$1/PROMPT_intake.md"
  local vendored_prompt="$2/templates/PROMPT_intake.md"

  if [ -f "$repo_prompt" ]; then
    printf '%s\n' "$repo_prompt"
    return 0
  fi

  if [ -f "$vendored_prompt" ]; then
    printf '%s\n' "$vendored_prompt"
    return 0
  fi

  return 1
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

PROMPT_SOURCE="$(resolve_prompt_source "$REPO_DIR" "$BOOTSTRAP_DIR" || true)"
if [ -z "$PROMPT_SOURCE" ]; then
  echo "Could not find PROMPT_intake.md in repo root or vendored Forgeloop templates." >&2
  echo "Reinstall or upgrade Forgeloop so the intake prompt is available." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_PATH")"
tmp_file="$(mktemp "${OUT_PATH}.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

cat > "$tmp_file" <<FORGELOOP_KICKOFF_PROMPT
# Kickoff Prompt (Forgeloop Spec Intake)

This file was rendered from the repo-local intake prompt.

- Repo: $REPO_DIR
- Prompt source: $PROMPT_SOURCE

## Project
- Name: $PROJECT_NAME
- Brief: $PROJECT_BRIEF
FORGELOOP_KICKOFF_PROMPT

if [ -n "$SEED_SOURCE" ]; then
  cat >> "$tmp_file" <<FORGELOOP_KICKOFF_PROMPT
- Seed source (optional): $SEED_SOURCE
FORGELOOP_KICKOFF_PROMPT
fi

if [ -n "$EXTRA_NOTES" ]; then
  cat >> "$tmp_file" <<FORGELOOP_KICKOFF_PROMPT
- Notes: $EXTRA_NOTES
FORGELOOP_KICKOFF_PROMPT
fi

cat >> "$tmp_file" <<'FORGELOOP_KICKOFF_PROMPT'

---

FORGELOOP_KICKOFF_PROMPT

cat "$PROMPT_SOURCE" >> "$tmp_file"
mv "$tmp_file" "$OUT_PATH"
trap - EXIT

echo "Wrote kickoff prompt: $OUT_PATH"
