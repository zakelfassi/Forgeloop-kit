# Forgeloop

[![v1.0.0](https://img.shields.io/badge/stable-v1.0.0-1fe38b)](https://github.com/zakelfassi/Forgeloop-kit/releases/tag/v1.0.0) [![v2 beta](https://img.shields.io/badge/next-v2%20(Elixir)-5b66ff)](https://github.com/zakelfassi/Forgeloop-kit/tree/main/elixir)

> **Forgeloop is the safe-autonomy layer for coding agents.**
>
> Install it in a repo, let Claude / Codex do real work, and when they start thrashing, Forgeloop pauses, preserves state, and drafts a clean human handoff instead of spinning forever.

Forgeloop is a vendorable, repo-local control plane for agentic software work.

It gives you four things that matter in practice:

1. **A repeatable loop** for planning and building against real repo checks
2. **Fail-closed backpressure** when the same failure keeps repeating
3. **Reviewable escalation artifacts** instead of silent retries and lost context
4. **Machine-readable runtime state** so humans and tooling can see what the agent is doing

Everything else in the kit—skills, knowledge capture, kickoff prompts, task lanes, log ingestion, runner provisioning—compounds on top of that control plane.

## The core promise

Most coding-agent demos show the happy path.

Forgeloop is about the unhappy path:

- the tests keep failing
- the same blocker stays unanswered
- auth breaks on one provider
- the loop needs to stop without losing the trail

When that happens, Forgeloop is designed to **fail closed, not spin**.

## What happens when an agent gets stuck

When a loop crosses the repeated-failure threshold, Forgeloop:

1. **Stops retrying**
2. **Writes `[PAUSE]` to `REQUESTS.md`**
3. **Drafts a human handoff in `ESCALATIONS.md`**
4. **Appends the blocking question to `QUESTIONS.md`**
5. **Writes machine-readable state to `.forgeloop/runtime-state.json`**

That artifact chain is the product.

## Prove it in under a minute

Install the kit into a target repo:

```bash
./install.sh /path/to/target-repo --wrapper
```

Then validate the control plane in that repo:

```bash
cd /path/to/target-repo
./forgeloop.sh evals
```

The eval suite is curated around the safe-autonomy story:

- daemon pause behavior
- repeated-failure escalation
- blocker escalation
- runtime-state transitions
- auth failover
- vendored vs repo-root entrypoint portability

See `evals/README.md` for the public proof surface.

## Quickstart

In the target repo:

```bash
./forgeloop.sh serve
./forgeloop.sh evals
./forgeloop.sh plan 1
./forgeloop.sh build 10
./forgeloop.sh workflow list
```

For continuous operation:

```bash
./forgeloop.sh daemon 300
```

That daemon is **interval-based**. It does not watch git in real time. It periodically checks the repo and control files, then decides whether to plan, build, pause, deploy, or ingest logs.

## Local operator UI (experimental)

Forgeloop now ships a loopback-only operator UI on top of the same file-backed control plane:

```bash
./forgeloop.sh serve
```

It is intentionally small and additive in this slice:

- served directly by the Elixir control-plane service
- live-updating via SSE
- interactive for pause, clear-pause, replan, question answer/resolve, and one-off `plan` / `build` runs
- the first operator surface referenced by new escalation drafts
- phase-1 backlog reads resolve from `FORGELOOP_IMPLEMENTATION_PLAN_FILE` (default `IMPLEMENTATION_PLAN.md`)
- no Phoenix, database, or Node asset pipeline
- canonical repo files and `.forgeloop/runtime-state.json` remain authoritative

If you run OpenClaw beside Forgeloop on the same host/VM, the repo now also ships a workspace plugin seam at `.openclaw/extensions/forgeloop/`. Start the service first, then let OpenClaw monitor/pilot the same loopback control plane instead of bypassing it. See `docs/openclaw.md`.

If you are working inside this repo directly, the equivalent command is:

```bash
cd elixir
mix forgeloop_v2.serve --repo ..
```

### Supported daemon control flags

Add these anywhere in `REQUESTS.md`:

- `[PAUSE]` — pause the daemon until removed
- `[REPLAN]` — run a planning pass before continuing
- `[WORKFLOW]` — managed daemon path: run one configured workflow target via `FORGELOOP_DAEMON_WORKFLOW_NAME` and `FORGELOOP_DAEMON_WORKFLOW_ACTION` (force `FORGELOOP_DAEMON_RUNTIME=bash` to stay on the legacy daemon path)
- `[DEPLOY]` — run `FORGELOOP_DEPLOY_CMD`
- `[INGEST_LOGS]` — analyze logs into a new request

`[PAUSE]` may also be inserted automatically by Forgeloop when it escalates a repeated failure or blocker.

## Three execution lanes

Forgeloop now has three execution lanes:

1. **Checklist lane** — `IMPLEMENTATION_PLAN.md` with `./forgeloop.sh plan|build`
2. **Tasks lane** — `prd.json` with `./forgeloop.sh tasks`
3. **Workflow lane (experimental)** — native Forgeloop workflow packs with `./forgeloop.sh workflow ...`

In phase 1 self-hosting, the checklist lane is the **canonical backlog** surfaced by the Elixir service, UI, OpenClaw seam, and orchestrator through `FORGELOOP_IMPLEMENTATION_PLAN_FILE` (default `IMPLEMENTATION_PLAN.md`). The tasks lane remains supported, but tracker/`prd.json` unification is intentionally deferred until after the UI core is stable.

The workflow lane is intentionally narrow in this slice: still runner-backed, still mapped onto the same runtime-state + escalation contract, and still manual-first. Workflow `preflight` / `run` actions flow through the managed Elixir babysitter + disposable-worktree path, the loopback service/HUD/OpenClaw seam exposes the same workflow control/status surface, and the daemon can now honor one explicit `[WORKFLOW]` marker by launching a single configured workflow target through that same managed path whenever the managed backend is active. The public `./forgeloop.sh daemon` command now prefers that managed backend by default and keeps `FORGELOOP_DAEMON_RUNTIME=bash` as an explicit legacy fallback. Elixir now also exposes a bounded workflow outcome/history sidecar beside the canonical workflow artifacts and active-run metadata, while broader workflow orchestration and native graph execution remain deferred. Elixir also keeps a read-only workflow catalog/artifact view plus a repo-local tracker projection that maps canonical backlog items and workflow packs into `Tracker.Issue` structs without mutating external trackers yet.

See `docs/workflows.md` for the detailed workflow-pack contract and checkpoint cadence.

## Why teams use it

- **Repo-local control plane** — vendor it into an existing repo without rebuilding your whole stack
- **Trust architecture** — repeated failures become explicit pauses and handoffs
- **State you can inspect** — the runtime always writes a machine-readable status file
- **Safer defaults** — `FORGELOOP_AUTOPUSH=false` by default
- **Model failover** — Claude/Codex routing with auth/rate-limit failover
- **Isolated-runner friendly** — designed for disposable VMs / containers when you run full-auto

## The runtime contract

The runtime source of truth lives in:

- `bin/loop.sh`
- `bin/forgeloop-daemon.sh`
- `bin/escalate.sh`
- `lib/core.sh`
- `lib/llm.sh`

The operator contract is documented in:

- `docs/runtime-control.md`
- `docs/workflows.md`
- `docs/sandboxing.md`

## Versioning

| Version | Status | Runtime | Pin to it |
|---------|--------|---------|-----------|
| [v1.0.0](https://github.com/zakelfassi/Forgeloop-kit/releases/tag/v1.0.0) | **Stable** | Bash | `git checkout v1.0.0` |
| v2 (main) | In development | Elixir + Bash | `git checkout main` |

If you want to stay on the stable bash-only runtime, pin to `v1.0.0`. The `main` branch carries v2 development — the Elixir foundation grows in parallel while the bash runtime remains fully functional.

## Elixir v2 foundation

An Elixir rewrite foundation now lives in `elixir/`. It is additive: the bash runtime remains available while the Elixir foundation grows toward feature parity.

Elixir now ships three experimental operator/runtime surfaces in `elixir/`: `mix forgeloop_v2.babysit build --repo ..` launches one manual child run in a disposable git worktree, `mix forgeloop_v2.daemon --repo ..` now routes checklist `plan` / `build`, deploy/log-ingest daemon actions, and one explicit `[WORKFLOW]` request through that same babysitter/worktree substrate or matching daemon helpers, and `mix forgeloop_v2.serve --repo ..` starts a loopback-only control-plane service that serves both JSON endpoints and a static live-updating UI for runtime/backlog/repo-local-tracker/questions/escalations/events/workflows/provider health plus babysitter visibility/control. In phase 1, that backlog is explicitly the configured implementation plan file (`FORGELOOP_IMPLEMENTATION_PLAN_FILE`, default `IMPLEMENTATION_PLAN.md`), not a unified tracker/tasks abstraction yet. The HUD and OpenClaw seam now also expose a read-only repo-local tracker projection that maps canonical backlog items and workflow packs into `Tracker.Issue`-shaped structs without mutating external trackers. The UI can now request pause/clear-pause/replan, answer or resolve questions, launch one-off `plan` / `build` runs through the babysitter with `surface: "ui"`, and trigger managed workflow `preflight` / `run` actions over the same control plane. JSONL under `.forgeloop/v2/events.log` remains the canonical event store, `/api/events` now exposes bounded event tails/replay with stable event ids, and `/api/stream` now bootstraps with a snapshot and then replays/live-streams canonical events over SSE instead of polling overview snapshots. Workflow read models now include canonical `last-preflight.txt` / `last-run.txt`, live `active-run.json`, and a bounded structured history sidecar for recent terminal outcomes. The repo also now ships an OpenClaw workspace plugin seam at `.openclaw/extensions/forgeloop/`, which talks to the same loopback service, uses `surface: "openclaw"` for manual runs, and can pilot workflow actions through the same babysitter/worktree path instead of inventing a side channel. All of these surfaces keep `IMPLEMENTATION_PLAN.md`, `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, and `.forgeloop/runtime-state.json` canonical at repo root. The public `./forgeloop.sh daemon` command now prefers the managed Elixir backend when `mix` + `forgeloop/elixir` are available, while `FORGELOOP_DAEMON_RUNTIME=bash` preserves an explicit legacy fallback. Broader workflow orchestration, native graph execution, event compaction/search, and tracker/`prd.json` unification are still not implemented.

Current coexistence rule:

- simultaneous bash + Elixir active control of one repo is unsupported
- Elixir records and checks an active-runtime claim under `.forgeloop/v2/active-runtime.json`
- conflicting ownership currently stops Elixir at claim time
- this is an Elixir-side guard, not a full cross-runtime lock or split-brain-prevention guarantee

Current scope:

- runtime-state JSON compatibility
- control-file + escalation artifact parity
- repeated-failure and blocker tracking
- a small GenServer daemon baseline whose Elixir checklist `plan` / `build` actions now route through the babysitter + disposable-worktree path
- initial provider failover tests
- runtime transition validation, metadata-first workspace safety, local event history, locked repo-safe mutation helpers for `REQUESTS.md` / `QUESTIONS.md`, managed workflow actions plus visibility over workflow catalogs + latest workflow artifacts, a manual single-child disposable-worktree babysitter skeleton, and a loopback control-plane service + interactive SSE-backed operator UI in Elixir

When v2 reaches feature parity, it will be tagged `v2.0.0-beta.1`.

See `elixir/README.md` for the current scope and how to run `mix test`.
- `docs/v2-roadmap.md`
- `docs/elixir-parity-matrix.md`
- `evals/README.md`

### Runtime states

`.forgeloop/runtime-state.json` is the machine-readable source of truth.

- `status` is the coarse operator state (`running`, `blocked`, `paused`, `awaiting-human`, `recovered`, `idle`)
- `transition` carries the detailed lifecycle step (`planning`, `building`, `retrying`, `escalated`, `completed`, etc.)
- `surface` tells you which surface wrote the state (`loop`, `daemon`, etc.)
- `mode` tells you which run mode is active (`build`, `plan`, `tasks`, `daemon`, etc.)

## Run safely

If you use auto-permissions / full-auto mode, treat the **VM or container as the security boundary**.

Disposable git worktrees are now part of the experimental self-hosting story in Elixir, but they are still a repo-internal hygiene boundary inside that VM/container, not a replacement for it.

- Guide: `docs/sandboxing.md`
- GCP runner helper: `ops/gcp/provision.sh`

Quick provision example:

```bash
OPENAI_API_KEY=... ANTHROPIC_API_KEY=... \
  ops/gcp/provision.sh --name forgeloop-runner \
  --project <gcp-project> --zone us-central1-a
```

## What it installs

Forgeloop vendors into `./forgeloop` and writes the control surfaces at repo root:

- `AGENTS.md`
- `PROMPT_plan.md`
- `PROMPT_build.md`
- `IMPLEMENTATION_PLAN.md`
- `REQUESTS.md`
- `QUESTIONS.md`
- `STATUS.md`
- `CHANGELOG.md`
- `system/knowledge/*`
- `system/experts/*`

That gives agents and operators a consistent repo-local operating surface instead of ad hoc prompt glue.

## Secondary systems that compound

These are real capabilities, but they are not the lead story.

### Skills

Forgeloop includes Skills tooling (`skillforge`, `sync-skills`, repo-local `skills/`) so repeated workflows can become reusable procedures for Codex / Claude Code.

```bash
./forgeloop.sh sync-skills
./forgeloop.sh sync-skills --all
```

### Knowledge capture

Session hooks can load and capture durable repo-local knowledge:

```bash
./forgeloop.sh session-start
./forgeloop.sh session-end
```

### Kickoff

For greenfield projects, generate a prompt for a memory-backed agent to produce `docs/*` and `specs/*`:

```bash
./forgeloop.sh kickoff "<one paragraph project brief>"
```

### Tasks lane

If you want machine-readable task execution instead of a markdown checklist:

> Phase-1 note: this lane is still optional and is **not** the canonical backlog surfaced by the loopback service/UI yet.


```bash
./forgeloop.sh tasks 10
```

### Log ingestion

Turn runtime logs into new requests:

```bash
./forgeloop.sh ingest-logs --file /path/to/logs.txt
```

or configure `[INGEST_LOGS]` in `REQUESTS.md` for daemon-driven ingestion.

## Install / upgrade patterns

Install into another repo from this repo:

```bash
./install.sh /path/to/target-repo --wrapper
```

If the kit is already vendored:

```bash
./forgeloop/install.sh --wrapper
```

Upgrade an existing vendored repo:

```bash
./forgeloop.sh upgrade --from /path/to/newer-forgeloop-kit --force
```

## Project layout

Key top-level paths in this repo:

- `bin/` — loop runtime, daemon, escalation, sync, kickoff, ingestion
- `lib/` — shared runtime helpers and LLM routing
- `docs/` — operator docs
- `evals/` — public proof suite
- `templates/` — installed repo surfaces
- `tests/` — broader regression suite
- `ops/gcp/` — dedicated runner provisioning

## Credits / inspiration

- [how-to-ralph-wiggum](https://github.com/ghuntley/how-to-ralph-wiggum)
- [marge-simpson](https://github.com/Soupernerd/marge-simpson)
- [compound-product](https://github.com/snarktank/compound-product)

Landing page: https://forgeloop.zakelfassi.com
