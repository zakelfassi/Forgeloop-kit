# Forgeloop v2 (Elixir foundation)

This directory contains the first runnable Elixir baseline for Forgeloop v2.

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
- persistent workspaces
- app-server orchestration
- Postgres/event pipeline

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
