#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v mix >/dev/null 2>&1; then
  echo "skip: service entrypoint layouts (mix not available)"
  exit 0
fi

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "FAIL: expected output to contain: $needle" >&2
    exit 1
  fi
}

prepare_repo_root_layout() {
  local target_root="$1"
  cp -R "$ROOT_DIR/bin" "$target_root/bin"
  cp -R "$ROOT_DIR/lib" "$target_root/lib"
  cp "$ROOT_DIR/config.sh" "$target_root/"
  cp -R "$ROOT_DIR/elixir" "$target_root/elixir"
  printf '# done\n' > "$target_root/IMPLEMENTATION_PLAN.md"
  : > "$target_root/REQUESTS.md"
  : > "$target_root/QUESTIONS.md"
  : > "$target_root/ESCALATIONS.md"
}

seed_git_repo() {
  local repo_dir="$1"

  rm -rf \
    "$repo_dir/elixir/_build" \
    "$repo_dir/elixir/deps" \
    "$repo_dir/forgeloop/elixir/_build" \
    "$repo_dir/forgeloop/elixir/deps"

  cat >> "$repo_dir/.gitignore" <<'EOF'
elixir/_build/
elixir/deps/
forgeloop/elixir/_build/
forgeloop/elixir/deps/
EOF

  (
    cd "$repo_dir"
    git init >/dev/null
    git config user.email 'tests@example.com'
    git config user.name 'Service Layout Smoke'
    git config commit.gpgsign false
    git add .
    git commit -m 'seed service smoke repo' >/dev/null
    git branch -M main >/dev/null 2>&1 || true
  )
}

start_service_and_assert() {
  local repo_dir="$1"
  local start_cmd="$2"
  local runtime_dir
  runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/forgeloop-service-smoke.XXXXXX")"
  local out_file="$runtime_dir/service.out"
  local pid=""

  mkdir -p "$runtime_dir" "$runtime_dir/hex-home" "$runtime_dir/mix-home"

  cleanup_service() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$runtime_dir"
  }

  trap cleanup_service RETURN

  (
    cd "$repo_dir"
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
    FORGELOOP_SHELL_DRIVER_ENABLED=false \
    HEX_HOME="$runtime_dir/hex-home" \
    MIX_HOME="$runtime_dir/mix-home" \
    exec bash -lc "$start_cmd"
  ) >"$out_file" 2>&1 &
  pid=$!

  local base_url=""
  local deadline=$((SECONDS + 90))

  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$out_file" >&2
      echo "FAIL: service exited during bootstrap smoke: $start_cmd" >&2
      exit 1
    fi

    base_url="$(sed -n 's/.*Forgeloop v2 operator UI ready at \(http:\/\/[^ ]*\).*/\1/p' "$out_file" | tail -n 1)"
    if [[ -n "$base_url" ]]; then
      break
    fi

    sleep 1
  done

  if [[ -z "$base_url" ]]; then
    cat "$out_file" >&2
    echo "FAIL: service did not report a loopback base URL" >&2
    exit 1
  fi

  local health
  local schema
  local html
  local slot_create
  local slot_list
  local slot_detail
  local slot_stop
  health="$(curl -fsS "$base_url/health")"
  schema="$(curl -fsS "$base_url/api/schema")"
  html="$(curl -fsS "$base_url/")"

  assert_contains "$health" '"ok":true'
  assert_contains "$health" '"service":"forgeloop_v2"'
  assert_contains "$schema" '"contract_name":"forgeloop_loopback"'
  assert_contains "$schema" '"contract_version":1'
  assert_contains "$schema" '"/api/slots"'
  assert_contains "$html" 'Forgeloop Operator HUD'

  slot_create="$(curl -fsS -X POST "$base_url/api/slots" -H 'content-type: application/json' -d '{"lane":"checklist","action":"plan","surface":"service","ephemeral":true}')"
  assert_contains "$slot_create" '"slot_id"'
  assert_contains "$slot_create" '"lane":"checklist"'
  assert_contains "$slot_create" '"action":"plan"'

  local slot_id
  slot_id="$(jq -r '.data.slot_id' <<<"$slot_create")"
  if [[ -z "$slot_id" || "$slot_id" == "null" ]]; then
    echo "$slot_create" >&2
    echo "FAIL: slot create response did not return a slot_id" >&2
    exit 1
  fi

  slot_list="$(curl -fsS "$base_url/api/slots")"
  jq -e --arg slot_id "$slot_id" '.data.counts.total >= 1 and any(.data.items[]; .slot_id == $slot_id and .lane == "checklist" and .action == "plan")' >/dev/null <<<"$slot_list" || {
    echo "$slot_list" >&2
    echo "FAIL: slot list did not expose the started slot" >&2
    exit 1
  }

  slot_detail="$(curl -fsS "$base_url/api/slots/$slot_id")"
  jq -e --arg slot_id "$slot_id" '.data.slot_id == $slot_id and .data.write_class == "read" and (.data.coordination_paths.requests | type == "string")' >/dev/null <<<"$slot_detail" || {
    echo "$slot_detail" >&2
    echo "FAIL: slot detail did not expose the expected slot metadata" >&2
    exit 1
  }

  slot_stop="$(curl -fsS -X POST "$base_url/api/slots/$slot_id/stop" -H 'content-type: application/json' -d '{"reason":"kill"}')"
  jq -e --arg slot_id "$slot_id" '.data.slot_id == $slot_id and (.data.status == "stopping" or .data.status == "blocked" or .data.status == "completed" or .data.status == "stopped")' >/dev/null <<<"$slot_stop" || {
    echo "$slot_stop" >&2
    echo "FAIL: slot stop did not return the slot metadata" >&2
    exit 1
  }
}

tmp_root="$(mktemp -d)"
tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_target"' EXIT

prepare_repo_root_layout "$tmp_root"
seed_git_repo "$tmp_root"
start_service_and_assert "$tmp_root" 'cd elixir && mix deps.get >/dev/null && mix compile >/dev/null && exec mix forgeloop_v2.serve --repo .. --port 0'

"$ROOT_DIR/install.sh" "$tmp_target" --force --wrapper >/dev/null
seed_git_repo "$tmp_target"
start_service_and_assert "$tmp_target" 'cd forgeloop/elixir && mix deps.get >/dev/null && mix compile >/dev/null && exec mix forgeloop_v2.serve --repo .. --port 0'

wrapper_help="$(cd "$tmp_target" && ./forgeloop.sh --help 2>&1)"
assert_contains "$wrapper_help" './forgeloop.sh serve [--host 127.0.0.1] [--port 4010]'

echo "ok: service entrypoint layouts"
