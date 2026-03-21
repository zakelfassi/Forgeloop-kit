# Forgeloop v2 (Elixir foundation)

This directory contains the first runnable Elixir baseline for Forgeloop v2.

Important framing:

- bash is still the default operational runtime
- Elixir is an experimental parity layer, not a replacement yet
- simultaneous bash + Elixir active control of the same repo is unsupported
- Elixir records and checks `.forgeloop/v2/active-runtime.json` at claim time
- conflicting ownership currently stops Elixir, but this is an Elixir-side coexistence guard rather than a full cross-runtime lock

Current scope:

- repo/path resolution for repo-root and vendored layouts
- runtime-state JSON compatibility
- control-file and escalation artifact writing
- repeated-failure and blocker-loop tracking
- noop/shell work drivers
- a small GenServer daemon
- provider auth/rate-limit failover unit coverage
- locked repo-safe mutation helpers for `REQUESTS.md` / `QUESTIONS.md` so pause/replan flags and question answers can be updated safely without faking runtime recovery
- workflow package catalog discovery plus a read-only visibility service for latest workflow preflight/run artifacts in the manual/external-runner workflow lane (see `../docs/workflows.md` for the detailed contract)
- a manual single-child babysitter/supervisor that launches `Loop.run/3` inside a disposable git worktree while keeping repo-root control artifacts canonical
- a loopback-only control-plane service that exposes runtime, the phase-1 canonical backlog from `FORGELOOP_IMPLEMENTATION_PLAN_FILE` (default `IMPLEMENTATION_PLAN.md`), a read-only repo-local tracker projection, questions, escalations, events, workflows, provider health, and babysitter start/stop/status over the existing file-first control plane
- a static repo-local operator UI served directly by that service, with SSE-backed live snapshots and interactive controls for pause/clear-pause/replan/question answer-resolve/manual plan-build runs, all still backed by the same canonical files and babysitter path
- a repo-local OpenClaw workspace plugin seam at `../.openclaw/extensions/forgeloop/` that talks to the same loopback service and uses `surface: "openclaw"` for manual runs

The next integration slice is still ahead of us: daemon scheduling through the babysitter, stronger ownership semantics if worktree-aware claims ever land, native graph execution beyond the current external workflow runner path, and workflow-lane babysitting on top of the current OpenClaw/UI/service seams.

Still intentionally deferred:

- tracker/`prd.json` backlog unification beyond the current phase-1 implementation-plan surface
- Phoenix UI
- tracker mutation tooling beyond the current read-only repo-local projection + memory adapter
- persistent workspaces and long-lived worktree management
- app-server orchestration
- Postgres/event pipeline
- OpenClaw as a supported provider/runtime option today

See `../docs/v2-roadmap.md` and `../docs/elixir-parity-matrix.md` for the current coexistence and validation story.

## Run tests

```bash
cd elixir
mix deps.get
mix test
```

## Run one daemon cycle

```bash
cd elixir
mix forgeloop_v2.daemon --once --repo ..
```

## Run one manual babysitter cycle

```bash
cd elixir
mix forgeloop_v2.babysit build --repo ..
```

## Run the loopback control-plane service + UI

```bash
cd elixir
mix forgeloop_v2.serve --repo ..
```

