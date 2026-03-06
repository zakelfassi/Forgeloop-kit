#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

mkdir -p "$tmp_repo/bin" "$tmp_repo/lib"
cp "$ROOT_DIR/bin/escalate.sh" "$tmp_repo/bin/"
cp "$ROOT_DIR/lib/core.sh" "$tmp_repo/lib/"
cp "$ROOT_DIR/config.sh" "$tmp_repo/"
chmod +x "$tmp_repo/bin/escalate.sh"

source "$tmp_repo/lib/core.sh"

export FORGELOOP_RUNTIME_DIR="$tmp_repo/.forgeloop-test"
export FORGELOOP_FAILURE_ESCALATE_AFTER=2
export FORGELOOP_FAILURE_ESCALATION_ACTION=issue

evidence_file="$tmp_repo/evidence.txt"
printf 'CI still failing on the same command\n' > "$evidence_file"

if forgeloop_core__handle_repeated_failure "$tmp_repo" "ci" "CI gate failed on main" "$evidence_file" ""; then
  echo "FAIL: first repeated failure should retry, not escalate" >&2
  exit 1
fi

if ! forgeloop_core__handle_repeated_failure "$tmp_repo" "ci" "CI gate failed on main" "$evidence_file" ""; then
  echo "FAIL: second repeated failure should escalate" >&2
  exit 1
fi

if ! grep -q '\[PAUSE\]' "$tmp_repo/REQUESTS.md"; then
  echo "FAIL: escalation should pause the daemon via REQUESTS.md" >&2
  exit 1
fi

if ! grep -q 'Forgeloop stopped after repeated `ci` failure' "$tmp_repo/QUESTIONS.md"; then
  echo "FAIL: escalation should draft a question for the user" >&2
  exit 1
fi

if ! grep -q 'Suggested command' "$tmp_repo/ESCALATIONS.md"; then
  echo "FAIL: escalation should draft an operator command" >&2
  exit 1
fi

echo "ok: failure escalation"
