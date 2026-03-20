#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if ! grep -Fq "$needle" <<<"$haystack"; then
        echo "FAIL: expected output to contain: $needle" >&2
        exit 1
    fi
}

assert_not_contains_line() {
    local haystack="$1"
    local needle="$2"

    if grep -Fxq "$needle" <<<"$haystack"; then
        echo "FAIL: expected output to omit line: $needle" >&2
        exit 1
    fi
}

plain_target="$tmp_root/plain-target"
wrapper_target="$tmp_root/wrapper-target"
mkdir -p "$plain_target" "$wrapper_target"

plain_output="$("$ROOT_DIR/install.sh" "$plain_target" --force 2>&1)"
wrapper_output="$("$ROOT_DIR/install.sh" "$wrapper_target" --force --wrapper 2>&1)"

assert_contains "$plain_output" "bash ./forgeloop/evals/run.sh"
assert_not_contains_line "$plain_output" "  ./forgeloop/evals/run.sh"
assert_contains "$plain_output" "./forgeloop/bin/loop.sh plan 1"
assert_contains "$plain_output" "./forgeloop/bin/loop.sh 5"
assert_contains "$plain_output" "./forgeloop/bin/workflow.sh list"

assert_contains "$wrapper_output" "./forgeloop.sh evals"
assert_contains "$wrapper_output" "./forgeloop.sh plan 1"
assert_contains "$wrapper_output" "./forgeloop.sh build 5"
assert_contains "$wrapper_output" "./forgeloop.sh workflow list"

echo "ok: install output"
