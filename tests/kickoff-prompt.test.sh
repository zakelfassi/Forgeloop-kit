#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

target_repo="$tmp_root/target-repo"
mkdir -p "$target_repo"

"$ROOT_DIR/install.sh" "$target_repo" --force --wrapper >/dev/null

[[ -f "$target_repo/PROMPT_intake.md" ]] || { echo "FAIL: install missing PROMPT_intake.md" >&2; exit 1; }
[[ -f "$target_repo/PROMPT_tasks.md" ]] || { echo "FAIL: install missing PROMPT_tasks.md" >&2; exit 1; }

(
  cd "$target_repo"
  ./forgeloop.sh kickoff "A calm collaborative writing app" --project aurora >/dev/null
)

kickoff_file="$target_repo/docs/KICKOFF_PROMPT.md"
[[ -f "$kickoff_file" ]] || { echo "FAIL: kickoff did not write docs/KICKOFF_PROMPT.md" >&2; exit 1; }

grep -Fq -- "- Name: aurora" "$kickoff_file" || { echo "FAIL: kickoff prompt missing project header" >&2; exit 1; }
grep -Fq -- "- Brief: A calm collaborative writing app" "$kickoff_file" || { echo "FAIL: kickoff prompt missing brief header" >&2; exit 1; }
grep -Fq -- "Default to the **checklist lane** unless the requester explicitly asks for a different lane." "$kickoff_file" || {
  echo "FAIL: kickoff prompt missing checklist-first guidance" >&2
  exit 1
}

echo "CUSTOM_INTAKE_SENTINEL" >> "$target_repo/PROMPT_intake.md"

(
  cd "$target_repo"
  ./forgeloop.sh kickoff "A calm collaborative writing app" --project aurora >/dev/null
)

grep -Fq -- "CUSTOM_INTAKE_SENTINEL" "$kickoff_file" || {
  echo "FAIL: kickoff prompt did not render repo-local PROMPT_intake.md" >&2
  exit 1
}

mv "$target_repo/PROMPT_intake.md" "$target_repo/PROMPT_intake.md.bak"
echo "VENDORED_FALLBACK_SENTINEL" >> "$target_repo/forgeloop/templates/PROMPT_intake.md"

(
  cd "$target_repo"
  ./forgeloop.sh kickoff "A calm collaborative writing app" --project aurora >/dev/null
)

grep -Fq -- "VENDORED_FALLBACK_SENTINEL" "$kickoff_file" || {
  echo "FAIL: kickoff prompt did not fall back to vendored PROMPT_intake.md" >&2
  exit 1
}

echo "ok: kickoff prompt"
