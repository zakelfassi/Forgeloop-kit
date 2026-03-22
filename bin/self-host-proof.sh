#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"

REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true

usage() {
  cat <<'USAGE'
Usage:
  ./bin/self-host-proof.sh
  ./bin/self-host-proof.sh --help

Manual, release-oriented self-hosting proof for Forgeloop V2 alpha.

- uses the real loopback service + HUD
- drives the HUD with agent-browser
- isolates runtime/control artifacts into a temporary proof workspace
- stays outside default CI and ./forgeloop.sh evals

Installed wrapper equivalent:
  ./forgeloop.sh self-host-proof
USAGE
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "[self-host-proof] missing required command: $name" >&2
    exit 1
  fi
}

prepare_proof_artifacts() {
  local state_root="$1"
  local plan_source="$2"
  local control_dir="$state_root/control"
  local runtime_dir="$state_root/runtime"
  local plan_target="$control_dir/IMPLEMENTATION_PLAN.md"

  mkdir -p "$artifact_dir" "$control_dir" "$runtime_dir"

  : > "$control_dir/REQUESTS.md"
  : > "$control_dir/QUESTIONS.md"
  : > "$control_dir/ESCALATIONS.md"

  if [[ -f "$plan_source" ]]; then
    cp "$plan_source" "$plan_target"
  else
    cat > "$plan_target" <<'EOF'
# Implementation Plan

## Backlog

- [ ] Pending item
EOF
  fi
}

resolve_plan_source() {
  local repo_dir="$1"
  local configured="${FORGELOOP_IMPLEMENTATION_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"

  if [[ "$configured" != /* ]]; then
    configured="$repo_dir/$configured"
  fi

  printf '%s\n' "$configured"
}

prepare_proof_repo() {
  local source_repo="$1"
  local artifact_dir="$2"
  local proof_repo="$artifact_dir/proof-repo"

  if command -v git >/dev/null 2>&1 && git -C "$source_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$source_repo" worktree add --detach "$proof_repo" HEAD >/dev/null
    printf '%s\n' "$proof_repo"
    return 0
  fi

  printf '%s\n' "$source_repo"
}

copy_tree() {
  local source_dir="$1"
  local dest_dir="$2"

  [[ -d "$source_dir" ]] || return 0
  mkdir -p "$dest_dir"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$source_dir/" "$dest_dir/"
  else
    (cd "$source_dir" && tar -cf - .) | (cd "$dest_dir" && tar -xf -)
  fi
}

copy_untracked_path() {
  local source_repo="$1"
  local proof_repo="$2"
  local relative_path="$3"
  local source_path="$source_repo/$relative_path"
  local proof_path="$proof_repo/$relative_path"

  mkdir -p "$(dirname "$proof_path")"
  rm -rf "$proof_path"
  cp -R "$source_path" "$proof_path"
}

overlay_source_snapshot() {
  local source_repo="$1"
  local proof_repo="$2"
  local artifact_dir="$3"
  local patch_file="$artifact_dir/source-overlay.patch"
  local has_untracked=0
  local status_output=""

  if ! command -v git >/dev/null 2>&1 || ! git -C "$source_repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  git -C "$source_repo" diff --binary HEAD >"$patch_file"
  if [[ -s "$patch_file" ]]; then
    git -C "$proof_repo" apply --index "$patch_file"
  fi

  while IFS= read -r -d '' relative_path; do
    has_untracked=1
    copy_untracked_path "$source_repo" "$proof_repo" "$relative_path"
    git -C "$proof_repo" add -- "$relative_path"
  done < <(git -C "$source_repo" ls-files --others --exclude-standard -z)

  status_output="$(git -C "$proof_repo" status --porcelain)"
  if [[ -n "$status_output" || "$has_untracked" -eq 1 ]]; then
    git -C "$proof_repo" \
      -c user.name='Forgeloop Proof' \
      -c user.email='proof@local' \
      -c commit.gpgsign=false \
      commit --no-verify -m 'forgeloop self-host proof snapshot' >/dev/null
  fi
}

cleanup_proof_repo() {
  local source_repo="$1"
  local proof_repo="$2"
  local proof_state_dir="$3"
  local artifact_dir="$4"

  [[ "$proof_repo" != "$source_repo" ]] || return 0

  copy_tree "$proof_state_dir" "$artifact_dir/proof-state"

  if command -v git >/dev/null 2>&1; then
    git -C "$source_repo" worktree remove --force "$proof_repo" >/dev/null 2>&1 || true
    git -C "$source_repo" worktree prune >/dev/null 2>&1 || true
  fi
}

main() {
  case "${1:-}" in
    "" ) ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[self-host-proof] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac

  require_cmd mix

  local artifact_dir="${FORGELOOP_SELF_HOST_PROOF_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/forgeloop-self-host-proof.XXXXXX")}"
  local host="${FORGELOOP_SELF_HOST_PROOF_HOST:-127.0.0.1}"
  local port="${FORGELOOP_SELF_HOST_PROOF_PORT:-4047}"
  local plan_source
  plan_source="$(resolve_plan_source "$REPO_DIR")"
  local proof_repo
  proof_repo="$(prepare_proof_repo "$REPO_DIR" "$artifact_dir")"
  overlay_source_snapshot "$REPO_DIR" "$proof_repo" "$artifact_dir"
  local proof_forgeloop_dir
  proof_forgeloop_dir="$(forgeloop_core__resolve_forgeloop_dir "$proof_repo")"
  local proof_state_dir="$proof_repo/.forgeloop/self-host-proof"

  prepare_proof_artifacts "$proof_state_dir" "${FORGELOOP_SELF_HOST_PROOF_PLAN_SOURCE:-$plan_source}"

  export FORGELOOP_SELF_HOST_PROOF_REPO_ROOT="$proof_repo"
  export FORGELOOP_SELF_HOST_PROOF_FORGELOOP_ROOT="$proof_forgeloop_dir"
  export FORGELOOP_SELF_HOST_PROOF_ARTIFACT_DIR="$artifact_dir"
  export FORGELOOP_SELF_HOST_PROOF_PLAN_SOURCE="${FORGELOOP_SELF_HOST_PROOF_PLAN_SOURCE:-$plan_source}"
  export FORGELOOP_SELF_HOST_PROOF_HOST="$host"
  export FORGELOOP_SELF_HOST_PROOF_PORT="$port"
  export FORGELOOP_SHELL_DRIVER_ENABLED=false
  export FORGELOOP_RUNTIME_DIR="$proof_state_dir/runtime"
  export FORGELOOP_REQUESTS_FILE="$proof_state_dir/control/REQUESTS.md"
  export FORGELOOP_QUESTIONS_FILE="$proof_state_dir/control/QUESTIONS.md"
  export FORGELOOP_ESCALATIONS_FILE="$proof_state_dir/control/ESCALATIONS.md"
  export FORGELOOP_IMPLEMENTATION_PLAN_FILE="$proof_state_dir/control/IMPLEMENTATION_PLAN.md"

  echo "[self-host-proof] source repo root: $REPO_DIR"
  echo "[self-host-proof] proof repo root: $proof_repo"
  echo "[self-host-proof] forgeloop root: $proof_forgeloop_dir"
  echo "[self-host-proof] artifact dir: $artifact_dir"

  (
    cd "$proof_forgeloop_dir/elixir"
    mix deps.get >/dev/null
    mix compile >/dev/null
  )

  bash "$proof_forgeloop_dir/tests/manual/hud-contract.agent-browser.sh"
  local status=$?

  cleanup_proof_repo "$REPO_DIR" "$proof_repo" "$proof_state_dir" "$artifact_dir"
  exit "$status"
}

main "$@"
