#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_repo="$(mktemp -d)"
trap 'rm -rf "$tmp_repo"' EXIT

today="$(date '+%Y-%m-%d')"

# Install the kit into a fresh target repo structure.
"$ROOT_DIR/install.sh" "$tmp_repo" --force >/dev/null

assert_eq() {
  local expected="$1"
  local actual="$2"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: expected [$expected], got [$actual]" >&2
    exit 1
  fi
}

assert_file_exists() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "FAIL: missing file: $path" >&2
    exit 1
  fi
}

set_last_accessed() {
  local file="$1"
  local id="$2"
  local new_date="$3"
  local tmp
  tmp="$(mktemp)"
  awk -v target_id="$id" -v today="$new_date" '
    BEGIN { in_target=0 }
    /^### / {
      if ($0 ~ ("^### " target_id " [|]")) in_target=1
      else in_target=0
    }
    {
      if (in_target && $0 ~ /^- \*\*last_accessed\*\*:/) {
        sub(/:.*/, ": " today)
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

get_last_accessed() {
  local file="$1"
  local id="$2"
  awk -v target_id="$id" '
    BEGIN { in_target=0 }
    /^### / {
      if ($0 ~ ("^### " target_id " [|]")) in_target=1
      else in_target=0
    }
    in_target && $0 ~ /^- \*\*last_accessed\*\*:/ { sub(/^.*:[[:space:]]*/, "", $0); print; exit }
  ' "$file"
}

knowledge_dir="$tmp_repo/system/knowledge"
experts_dir="$tmp_repo/system/experts"
decisions_file="$knowledge_dir/decisions.md"
index_file="$knowledge_dir/_index.md"

assert_file_exists "$decisions_file"
assert_file_exists "$index_file"
assert_file_exists "$experts_dir/security.md"
assert_file_exists "$experts_dir/design.md"
assert_file_exists "$experts_dir/documentation.md"
assert_file_exists "$experts_dir/product.md"

# Generate session context and ensure it loads real entries (not the "Entry Format" codeblock).
export RALPH_RUNTIME_DIR="$tmp_repo/.ralph-test"
context_path="$(RALPH_TASK_CONTEXT='ui docs' "$tmp_repo/ralph/bin/session-start.sh" --quiet --no-stdout --print-path)"
assert_file_exists "$context_path"

if grep -q "D-###" "$context_path" 2>/dev/null; then
  echo "FAIL: session context should not include template placeholder entry (D-###)" >&2
  exit 1
fi

if ! grep -Eq "^### D-001[[:space:]]*[|]" "$context_path"; then
  echo "FAIL: expected D-001 to be loaded into session context" >&2
  exit 1
fi

if ! grep -q "^## Expert: Design" "$context_path"; then
  echo "FAIL: expected design expert to be loaded into session context" >&2
  exit 1
fi

# Create a second decision so we can verify access updates are entry-scoped.
"$tmp_repo/ralph/bin/session-end.sh" --capture decision "Second decision" "ctx" "dec" "" "tag1" >/dev/null

set_last_accessed "$decisions_file" "D-001" "2000-01-01"
set_last_accessed "$decisions_file" "D-002" "1999-01-01"

"$tmp_repo/ralph/bin/session-end.sh" --update-access "D-001" >/dev/null

assert_eq "$today" "$(get_last_accessed "$decisions_file" "D-001")"
assert_eq "1999-01-01" "$(get_last_accessed "$decisions_file" "D-002")"

# Index stats should count only numeric IDs (not the Entry Format "D-###" line).
"$tmp_repo/ralph/bin/session-end.sh" summary >/dev/null
if ! grep -q "^- Decisions: 2$" "$index_file"; then
  echo "FAIL: expected Decisions count to be 2 in _index.md" >&2
  exit 1
fi

echo "ok: session knowledge"
