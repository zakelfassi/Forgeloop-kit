# Elixir v2 Roadmap

Forgeloop v2 is an **experimental Elixir parity layer** growing beside the default bash runtime.

## Current Position

- Bash is still the default operational runtime.
- Elixir already implements the safety nucleus:
  - repo-root and vendored path resolution
  - `.forgeloop/runtime-state.json` compatibility
  - control-file helpers for `REQUESTS.md`, `QUESTIONS.md`, and `ESCALATIONS.md`
  - fail-closed escalation artifact writing
  - repeated-failure and blocker tracking
  - shell/noop work drivers
  - daemon baseline
  - workflow loading with last-known-good reload
  - tracker boundary plus memory adapter
  - metadata-first workspace and path-safety helpers
  - local JSONL event history

## Coexistence Rule

- Bash remains the default runtime for this phase.
- Elixir shares the same repo-local artifact contract and runtime-state shape.
- Running bash and Elixir as simultaneous active controllers for the same repo is unsupported.
- Elixir now records an active-runtime claim under `.forgeloop/v2/active-runtime.json` and treats conflicting ownership as a stop condition at claim time.
- This is currently an Elixir-side coexistence guard, not a full cross-runtime lock or split-brain-prevention guarantee unless bash participates in the same ownership signal.

## Current Workflow-Pack Lane

The active workflow direction is an **experimental manual workflow lane** for native Forgeloop workflow packs, executed through a configured runner while preserving Forgeloop’s repo-local fail-closed contract.

Architecturally, that lane is intentionally narrow:

- it adds a third lane instead of refactoring all loop types into one executor
- it keeps `WORKFLOW.md` as a prompt/config surface rather than widening it into a graph manifest
- it leaves native graph execution deferred until the workflow-pack lane is proven
- it keeps the workflow lane focused on native Forgeloop workflow packs rather than alternate product identities

Read-only Elixir visibility groundwork for workflow catalogs and latest workflow artifacts is now in place; HTTP/UI surfaces, babysitter supervision, and plugin integrations remain future work.

See `docs/workflows.md` for the detailed operator contract.

## Next Planned Slice

With parser/read-path groundwork and repo-safe mutation helpers now in place, the next runtime-isolation slice is:

1. sandboxed self-hosting via disposable git worktrees
2. a bounded babysitter/supervisor operating mode above the child loop
3. a future integration seam for external plugin surfaces such as OpenClaw

That slice is meant to preserve the same fail-closed artifact chain while making it safe to let Forgeloop work on Forgeloop inside a disposable worktree instead of directly against the canonical checkout.

## Next Acceptance Bar

Elixir is not promoted by feature count. It is promoted by preserving the bash fail-closed contract:

1. pause instead of spin
2. preserve the escalation artifact chain
3. keep runtime-state transitions legible and constrained
4. keep recovery explicit and safe
5. keep repo-root and vendored layouts working

The required local gates for each milestone are:

```bash
bash tests/run.sh
bash evals/run.sh
cd elixir && mix test
```

## Explicit Deferrals

These are still out of scope for the current phase:

- Phoenix UI and dashboard work
- Broadway or any hot-path queue/pipeline
- Postgres-backed event storage
- persistent workspace mirrors and long-lived worktree orchestration
- graph workflows
- exact checkpoint/resume
- multi-host workers
- raw tracker mutation tooling
- OpenClaw as a supported runtime/provider option today

