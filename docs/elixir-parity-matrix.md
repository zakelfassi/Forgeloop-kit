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
| Runtime ownership reclaim + fail-closed malformed ownership stay reviewable across bash, daemon, and loopback starts | `tests/runtime-ownership-reclaim.test.sh`, `tests/daemon-entrypoint-layouts.test.sh` | `elixir/test/forgeloop_v2/runtime_lifecycle_test.exs`, `elixir/test/forgeloop_v2/service_test.exs`, `elixir/test/forgeloop_v2/daemon_test.exs` | In progress |

## Notes

- Bash is still the public acceptance anchor.
- Elixir parity is measured on operator-visible artifacts and transitions first, not on internal implementation shape.
- A green Elixir unit suite is necessary but not sufficient; the bash proof surface must stay green while parity expands.
- Elixir now also has locked repo-safe mutation helpers for `REQUESTS.md` / `QUESTIONS.md`, a loopback control-plane service + interactive operator UI, a repo-local OpenClaw plugin seam for that same service, a read-only repo-local tracker projection for canonical backlog items + workflow packs, and managed workflow control/visibility over workflow artifacts; in phase 1 that service/UI backlog is the configured implementation plan file (`FORGELOOP_IMPLEMENTATION_PLAN_FILE`, default `IMPLEMENTATION_PLAN.md`), and that groundwork helps future UI/plugin work but is not yet a full bash-parity contract on its own.
- The current release hardening bar now also expects a shared loopback ownership/start-gate read model plus additive `error.ownership` context for blocked starts, not just raw runtime-owner visibility or green happy-path service tests.
- The current v2 alpha release bar now also includes a manual `./forgeloop.sh self-host-proof` pass for the real HUD/service path; it is intentionally separate from `evals` and CI.

## Current experimental v2-only extensions

These are now present in Elixir v2, but they are still experimental extensions rather than full bash-parity anchors:

- self-hosted runs in disposable worktrees preserve the same repo-local fail-closed artifact chain
- a single-child babysitter/supervisor can stop, recover, and clean up child runs without bypassing runtime-state transitions
- a loopback-only control-plane service + interactive static UI can expose the same repo-local state, including the phase-1 canonical backlog from `IMPLEMENTATION_PLAN.md`, without introducing a second source of truth
- that same service/UI layer now has a one-command manual self-host proof over the real HUD path using `agent-browser` and a disposable proof-repo snapshot
- that same service/UI/OpenClaw plane can now project a read-only tracker view from canonical backlog items and workflow packs without mutating external trackers yet
- manual workflow `preflight` / `run` actions can now flow through the same babysitter + disposable-worktree path exposed by the control plane instead of bypassing it
- Elixir-daemon checklist `plan` / `build` actions now reuse that same babysitter + disposable-worktree substrate, and the public `./forgeloop.sh daemon` command now prefers that managed path while keeping the legacy bash daemon as an explicit fallback
- the experimental Elixir daemon can now honor one explicit `[WORKFLOW]` request against a configured workflow target without bypassing that same managed path
- the current OpenClaw seam is loopback-only and preserves the same control surfaces instead of bypassing them
