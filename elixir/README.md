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

Still intentionally deferred:

- Phoenix UI
- tracker adapters
- persistent workspaces and worktrees
- app-server orchestration
- Postgres/event pipeline

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
