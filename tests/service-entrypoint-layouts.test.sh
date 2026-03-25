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

start_service_and_assert() {
  local repo_dir="$1"
  local start_cmd="$2"
  local runtime_dir="$repo_dir/.forgeloop-service-smoke"
  local out_file="$runtime_dir/service.out"
  local pid=""

  mkdir -p "$runtime_dir" "$runtime_dir/hex-home" "$runtime_dir/mix-home"

  cleanup_service() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  }

  trap cleanup_service RETURN

  (
    cd "$repo_dir"
    FORGELOOP_RUNTIME_DIR="$runtime_dir" \
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
  health="$(curl -fsS "$base_url/health")"
  schema="$(curl -fsS "$base_url/api/schema")"
  html="$(curl -fsS "$base_url/")"

  assert_contains "$health" '"ok":true'
  assert_contains "$health" '"service":"forgeloop_v2"'
  assert_contains "$schema" '"contract_name":"forgeloop_loopback"'
  assert_contains "$schema" '"contract_version":1'
  assert_contains "$html" 'Forgeloop Operator HUD'
}

tmp_root="$(mktemp -d)"
tmp_target="$(mktemp -d)"
trap 'rm -rf "$tmp_root" "$tmp_target"' EXIT

prepare_repo_root_layout "$tmp_root"
start_service_and_assert "$tmp_root" 'cd elixir && mix deps.get >/dev/null && mix compile >/dev/null && exec mix forgeloop_v2.serve --repo .. --port 0'

"$ROOT_DIR/install.sh" "$tmp_target" --force --wrapper >/dev/null
start_service_and_assert "$tmp_target" 'cd forgeloop/elixir && mix deps.get >/dev/null && mix compile >/dev/null && exec mix forgeloop_v2.serve --repo .. --port 0'

wrapper_help="$(cd "$tmp_target" && ./forgeloop.sh --help 2>&1)"
assert_contains "$wrapper_help" './forgeloop.sh serve [--host 127.0.0.1] [--port 4010]'

echo "ok: service entrypoint layouts"
