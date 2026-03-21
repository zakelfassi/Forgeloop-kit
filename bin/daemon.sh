#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$BOOTSTRAP_DIR/lib/core.sh"

REPO_DIR="$(forgeloop_core__resolve_repo_dir "${BASH_SOURCE[0]}")"
FORGELOOP_DIR="$(forgeloop_core__resolve_forgeloop_dir "$REPO_DIR")"
source "$FORGELOOP_DIR/config.sh" 2>/dev/null || true

RUNTIME_DIR="$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")"
LOG_FILE="${FORGELOOP_DAEMON_LOG_FILE:-$RUNTIME_DIR/logs/daemon.log}"
LOCK_FILE="${FORGELOOP_DAEMON_LOCK_FILE:-$RUNTIME_DIR/daemon.lock}"
BACKEND="${FORGELOOP_DAEMON_RUNTIME:-auto}"
DEFAULT_INTERVAL="${FORGELOOP_DAEMON_INTERVAL_SECONDS:-300}"

log() { forgeloop_core__log "$1" "$LOG_FILE"; }

interval="$DEFAULT_INTERVAL"
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  interval="$1"
  shift
fi

extra_args=("$@")

elixir_backend_available() {
  [[ -d "$FORGELOOP_DIR/elixir" ]] || return 1
  command -v mix >/dev/null 2>&1 || return 1
  return 0
}

elixir_backend_auto_ready() {
  [[ -f "$FORGELOOP_DIR/elixir/mix.exs" ]] || return 1
  (
    cd "$FORGELOOP_DIR/elixir"
    elixir_deps_present
  )
}

run_bash_backend() {
  log "Public daemon launcher selected legacy bash backend"

  if ((${#extra_args[@]})); then
    exec "$FORGELOOP_DIR/bin/forgeloop-daemon.sh" "$interval" "${extra_args[@]}"
  else
    exec "$FORGELOOP_DIR/bin/forgeloop-daemon.sh" "$interval"
  fi
}

elixir_deps_present() {
  [[ -d deps ]] || return 1
  find deps -mindepth 1 -maxdepth 1 | grep -q .
}

run_elixir_backend() {
  log "Public daemon launcher selected managed Elixir backend"
  cd "$FORGELOOP_DIR/elixir"

  export HEX_HOME="${FORGELOOP_HEX_HOME:-$RUNTIME_DIR/hex-home}"
  mkdir -p "$HEX_HOME"

  if [[ -n "${FORGELOOP_MIX_HOME:-}" ]]; then
    export MIX_HOME="$FORGELOOP_MIX_HOME"
    mkdir -p "$MIX_HOME"
  fi

  if ! elixir_deps_present; then
    mix deps.get >/dev/null
  fi

  mix compile >/dev/null

  if ((${#extra_args[@]})); then
    exec mix forgeloop_v2.daemon --repo "$REPO_DIR" --interval "$interval" "${extra_args[@]}"
  else
    exec mix forgeloop_v2.daemon --repo "$REPO_DIR" --interval "$interval"
  fi
}

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "Another daemon instance is running. Exiting."
  exit 0
fi

case "$BACKEND" in
  auto)
    if elixir_backend_available && elixir_backend_auto_ready; then
      run_elixir_backend >>"$LOG_FILE" 2>&1
    else
      log "Managed Elixir daemon not start-ready in auto mode; falling back to legacy bash backend"
      run_bash_backend >>"$LOG_FILE" 2>&1
    fi
    ;;
  elixir)
    if ! elixir_backend_available; then
      log "Managed Elixir daemon requested but mix or elixir app directory is unavailable"
      exit 1
    fi

    run_elixir_backend >>"$LOG_FILE" 2>&1
    ;;
  bash)
    run_bash_backend >>"$LOG_FILE" 2>&1
    ;;
  *)
    log "Invalid FORGELOOP_DAEMON_RUNTIME=$BACKEND"
    exit 1
    ;;
esac
