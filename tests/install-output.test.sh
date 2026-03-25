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

assert_order() {
    local haystack="$1"
    local first="$2"
    local second="$3"
    local first_line second_line

    first_line="$(grep -nF "$first" <<<"$haystack" | head -n1 | cut -d: -f1)"
    second_line="$(grep -nF "$second" <<<"$haystack" | head -n1 | cut -d: -f1)"

    if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
        echo "FAIL: expected '$first' to appear before '$second'" >&2
        exit 1
    fi
}

plain_target="$tmp_root/plain-target"
wrapper_target="$tmp_root/wrapper-target"
mkdir -p "$plain_target" "$wrapper_target"

plain_output="$("$ROOT_DIR/install.sh" "$plain_target" --force 2>&1)"
wrapper_output="$("$ROOT_DIR/install.sh" "$wrapper_target" --force --wrapper 2>&1)"
wrapper_help="$(cd "$wrapper_target" && ./forgeloop.sh --help 2>&1)"

[[ -f "$plain_target/AGENTS.md" ]] || { echo "FAIL: plain install missing AGENTS.md" >&2; exit 1; }
[[ -f "$plain_target/PROMPT_intake.md" ]] || { echo "FAIL: plain install missing PROMPT_intake.md" >&2; exit 1; }
[[ -f "$plain_target/PROMPT_tasks.md" ]] || { echo "FAIL: plain install missing PROMPT_tasks.md" >&2; exit 1; }
[[ -L "$plain_target/CLAUDE.md" ]] || { echo "FAIL: plain install CLAUDE.md is not a symlink" >&2; exit 1; }
[[ "$(readlink "$plain_target/CLAUDE.md")" == "AGENTS.md" ]] || { echo "FAIL: plain install CLAUDE.md points to $(readlink "$plain_target/CLAUDE.md")" >&2; exit 1; }
[[ -f "$wrapper_target/AGENTS.md" ]] || { echo "FAIL: wrapper install missing AGENTS.md" >&2; exit 1; }
[[ -f "$wrapper_target/PROMPT_intake.md" ]] || { echo "FAIL: wrapper install missing PROMPT_intake.md" >&2; exit 1; }
[[ -f "$wrapper_target/PROMPT_tasks.md" ]] || { echo "FAIL: wrapper install missing PROMPT_tasks.md" >&2; exit 1; }
[[ -L "$wrapper_target/CLAUDE.md" ]] || { echo "FAIL: wrapper install CLAUDE.md is not a symlink" >&2; exit 1; }
[[ "$(readlink "$wrapper_target/CLAUDE.md")" == "AGENTS.md" ]] || { echo "FAIL: wrapper install CLAUDE.md points to $(readlink "$wrapper_target/CLAUDE.md")" >&2; exit 1; }

assert_contains "$plain_output" "(cd ./forgeloop/elixir && mix forgeloop_v2.serve --repo ..)"
assert_contains "$plain_output" "bash ./forgeloop/evals/run.sh"
assert_not_contains_line "$plain_output" "  ./forgeloop/evals/run.sh"
assert_contains "$plain_output" "./forgeloop/bin/self-host-proof.sh"
assert_contains "$plain_output" "./forgeloop/bin/kickoff.sh \"<one paragraph project brief>\""
assert_contains "$plain_output" "./forgeloop/bin/loop.sh plan 1"
assert_contains "$plain_output" "./forgeloop/bin/loop.sh 5"
assert_contains "$plain_output" "./forgeloop/bin/workflow.sh list"
assert_order "$plain_output" "./forgeloop/bin/kickoff.sh \"<one paragraph project brief>\"" "./forgeloop/bin/loop.sh plan 1"

assert_contains "$wrapper_output" "./forgeloop.sh serve"
assert_contains "$wrapper_output" "./forgeloop.sh evals"
assert_contains "$wrapper_output" "./forgeloop.sh self-host-proof"
assert_contains "$wrapper_output" "./forgeloop.sh kickoff \"<one paragraph project brief>\""
assert_contains "$wrapper_output" "./forgeloop.sh plan 1"
assert_contains "$wrapper_output" "./forgeloop.sh build 5"
assert_contains "$wrapper_output" "./forgeloop.sh workflow list"
assert_order "$wrapper_output" "./forgeloop.sh kickoff \"<one paragraph project brief>\"" "./forgeloop.sh plan 1"
assert_contains "$wrapper_help" "./forgeloop.sh kickoff \"<brief>\""
assert_contains "$wrapper_help" "./forgeloop.sh serve [--host 127.0.0.1] [--port 4010]"
assert_contains "$wrapper_help" "./forgeloop.sh self-host-proof"
assert_order "$wrapper_help" "./forgeloop.sh kickoff \"<brief>\"" "./forgeloop.sh plan [max_iters] [--lite|--full] [--watch|--infinite]"

echo "ok: install output"
