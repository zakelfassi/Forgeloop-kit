# Elixir Parity Matrix

This matrix tracks the operator-visible contracts that bash already proves and the Elixir parity layer must preserve.

| Contract | Bash proof surface | Elixir proof surface | Status |
|---------|--------------------|----------------------|--------|
| Pause via `[PAUSE]` writes `paused` runtime state | `evals/scenarios/daemon-paused-flag.sh` | `elixir/test/forgeloop_v2/daemon_test.exs` | In progress |
| Repeated failure stops and escalates with repo-local artifacts | `tests/failure-escalation.test.sh`, `evals/scenarios/repeated-failure-state.sh` | `elixir/test/forgeloop_v2/failure_tracker_test.exs`, `elixir/test/forgeloop_v2/events_test.exs` | In progress |
| Repeated unanswered blocker escalates instead of spinning | `tests/daemon-blocker-escalation.test.sh` | `elixir/test/forgeloop_v2/blocker_detector_test.exs`, `elixir/test/forgeloop_v2/events_test.exs` | In progress |
| Runtime-state transitions stay legible and constrained | `tests/runtime-state-model.test.sh` | `elixir/test/forgeloop_v2/runtime_state_store_test.exs`, `elixir/test/forgeloop_v2/runtime_lifecycle_test.exs` | In progress |
| Recovery is explicit and safe | bash pause/resume behavior in daemon flows | `elixir/test/forgeloop_v2/daemon_test.exs`, `elixir/test/forgeloop_v2/orchestrator_test.exs` | In progress |
| Provider auth/rate-limit failover preserves forward progress | `tests/llm-auth-failover.test.sh` | `elixir/test/forgeloop_v2/llm_router_test.exs`, `elixir/test/forgeloop_v2/events_test.exs` | In progress |
| Repo-root and vendored layouts both work | `tests/daemon-entrypoint-layouts.test.sh` | `elixir/test/forgeloop_v2/repo_paths_test.exs` | In progress |

## Notes

- Bash is still the public acceptance anchor.
- Elixir parity is measured on operator-visible artifacts and transitions first, not on internal implementation shape.
- A green Elixir unit suite is necessary but not sufficient; the bash proof surface must stay green while parity expands.
- Elixir now also has locked repo-safe mutation helpers for `REQUESTS.md` / `QUESTIONS.md`, a loopback control-plane service + static operator UI, and a read-only workflow visibility seam over workflow artifacts; that groundwork helps future UI/plugin work but is not yet a full bash-parity contract on its own.

## Current experimental v2-only extensions

These are now present in Elixir v2, but they are still experimental extensions rather than full bash-parity anchors:

- self-hosted runs in disposable worktrees preserve the same repo-local fail-closed artifact chain
- a single-child babysitter/supervisor can stop, recover, and clean up child runs without bypassing runtime-state transitions
- a loopback-only control-plane service + static UI can expose the same repo-local state without introducing a second source of truth
- future external integration seams such as OpenClaw still need to preserve the same control surfaces instead of bypassing them

