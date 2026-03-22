#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected output to contain: $needle" >&2
    exit 1
  fi
}

repo_help="$("$ROOT_DIR/bin/self-host-proof.sh" --help 2>&1)"

assert_contains "$repo_help" "Manual, release-oriented self-hosting proof"
assert_contains "$repo_help" "real loopback service + HUD"
assert_contains "$repo_help" "agent-browser"
assert_contains "$repo_help" "outside default CI and ./forgeloop.sh evals"
assert_contains "$repo_help" "./forgeloop.sh self-host-proof"

tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_target"' EXIT

"$ROOT_DIR/install.sh" "$tmp_target" --force --wrapper >/dev/null
wrapper_help="$(cd "$tmp_target" && ./forgeloop.sh self-host-proof --help 2>&1)"

assert_contains "$wrapper_help" "Manual, release-oriented self-hosting proof"
assert_contains "$wrapper_help" "real loopback service + HUD"
assert_contains "$wrapper_help" "agent-browser"
assert_contains "$wrapper_help" "outside default CI and ./forgeloop.sh evals"

echo "ok: self-host proof entrypoint"
