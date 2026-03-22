#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

install_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir"
    "$ROOT_DIR/install.sh" "$repo_dir" --force --wrapper >/dev/null
}

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if ! grep -Fq "$needle" <<<"$haystack"; then
        echo "FAIL: expected output to contain: $needle" >&2
        exit 1
    fi
}

repo_a="$tmp_root/repo-a"
install_repo "$repo_a"

# Helper-level readiness: fresh install should not be ready.
(
    source "$repo_a/forgeloop/lib/core.sh"
    if forgeloop_core__check_checklist_intake_readiness "$repo_a" "$repo_a/forgeloop"; then
        echo "FAIL: fresh install should not be intake-ready" >&2
        exit 1
    fi
)

# Rendering kickoff alone should still not make checklist intake ready.
(
    cd "$repo_a"
    ./forgeloop.sh kickoff "A greenfield repo" >/dev/null
)
(
    source "$repo_a/forgeloop/lib/core.sh"
    if forgeloop_core__check_checklist_intake_readiness "$repo_a" "$repo_a/forgeloop"; then
        echo "FAIL: kickoff artifact alone should not satisfy intake readiness" >&2
        exit 1
    fi
)

# A real spec file should make the checklist lane ready.
cat > "$repo_a/specs/product.md" <<'EOF'
# Product Spec

- Real implementation-ready spec content.
EOF

(
    source "$repo_a/forgeloop/lib/core.sh"
    forgeloop_core__check_checklist_intake_readiness "$repo_a" "$repo_a/forgeloop" || {
        echo "FAIL: real spec file should satisfy intake readiness" >&2
        exit 1
    }
)

repo_b="$tmp_root/repo-b"
install_repo "$repo_b"

# A real plan item should also count as ready.
cat > "$repo_b/IMPLEMENTATION_PLAN.md" <<'EOF'
# Implementation Plan

## Next Up
- [ ] Ship the real first feature slice
EOF

(
    source "$repo_b/forgeloop/lib/core.sh"
    forgeloop_core__check_checklist_intake_readiness "$repo_b" "$repo_b/forgeloop" || {
        echo "FAIL: real plan item should satisfy intake readiness" >&2
        exit 1
    }
)

repo_c="$tmp_root/repo-c"
install_repo "$repo_c"

set +e
plan_output="$(cd "$repo_c" && ./forgeloop.sh plan 1 2>&1)"
plan_status=$?
build_output="$(cd "$repo_c" && ./forgeloop.sh build 1 2>&1)"
build_status=$?
set -e

[[ "$plan_status" -eq 2 ]] || { echo "FAIL: fresh plan should exit 2, got $plan_status" >&2; exit 1; }
[[ "$build_status" -eq 2 ]] || { echo "FAIL: fresh build should exit 2, got $build_status" >&2; exit 1; }

assert_contains "$plan_output" "Checklist intake is not ready yet."
assert_contains "$plan_output" "PROMPT_intake.md"
assert_contains "$plan_output" "./forgeloop.sh kickoff \"<one paragraph project brief>\""
assert_contains "$plan_output" "docs/KICKOFF_PROMPT.md"
assert_contains "$build_output" "Checklist lane remains the default. Tasks/workflow lanes stay explicit opt-ins."

[[ ! -f "$repo_c/.forgeloop/runtime-state.json" ]] || {
    echo "FAIL: intake gate should not write runtime-state.json before exiting" >&2
    exit 1
}
[[ ! -f "$repo_c/.forgeloop/v2/active-runtime.json" ]] || {
    echo "FAIL: intake gate should not claim active-runtime before exiting" >&2
    exit 1
}

echo "ok: intake lifecycle"
