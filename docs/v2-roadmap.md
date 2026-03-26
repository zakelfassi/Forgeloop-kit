# Elixir v2 Roadmap

This page describes the current **v2 alpha / development track on `main`**.

Forgeloop v2 is an **experimental Elixir parity layer** growing beside the default bash runtime, not a stable or beta release claim. See `docs/release-tracks.md` for the stable-v1 vs mainline-v2 track split.

## Current Position

- Bash is still the default operational runtime.
- Elixir already implements the safety nucleus:
  - repo-root and vendored path resolution
  - `.forgeloop/runtime-state.json` compatibility
  - control-file helpers for `REQUESTS.md`, `QUESTIONS.md`, and `ESCALATIONS.md`
  - fail-closed escalation artifact writing
  - repeated-failure and blocker tracking
  - shell/noop work drivers
  - daemon baseline with checklist `plan` / `build` routed through babysitter-managed disposable worktrees on the Elixir path
  - workflow loading with last-known-good reload
  - tracker boundary plus memory adapter and a repo-local projection seam
  - metadata-first workspace and path-safety helpers
  - local JSONL event history with bounded tail/replay readers and live subscriptions for the control plane
- a loopback-only control-plane service for runtime plus the phase-1 canonical backlog from `FORGELOOP_IMPLEMENTATION_PLAN_FILE` (default `IMPLEMENTATION_PLAN.md`), a read-only repo-local tracker projection, and questions/escalations/events/workflows/provider health plus babysitter control
- a versioned loopback contract descriptor at `/api/schema` plus additive top-level `api` metadata on JSON and SSE envelopes, so the HUD and OpenClaw can follow one explicit service-owned schema while keeping older-service fallbacks where intended
- an additive service-owned `ownership` start-gate read model plus additive `error.ownership` context on blocked starts, so live conflicts, reclaimable claims, stale cleanup, and malformed metadata stay explicit across the HUD and OpenClaw seam
- a static repo-local operator UI with replayable SSE-backed live updates, interactive control mutations, and no Node asset pipeline
- a one-command manual `./forgeloop.sh self-host-proof` harness for the real loopback service + HUD path, using `agent-browser` plus a disposable proof-repo snapshot when git is available instead of mutating the live checkout
- a seeded demo repo plus `./bin/capture-product-screenshots.sh` path for reproducible public HUD screenshots rendered from real loopback state
- a repo-local OpenClaw workspace plugin seam that targets the same loopback control plane instead of bypassing it, including a shared service-owned coordination read model for HUD/OpenClaw, a bounded operator brief/timeline, one-window bounded playbooks/recommendations, and conservative optional one-action apply
- an experimental multi-slot coordinator for parallel read-heavy managed runs, with slot-scoped worktree/runtime metadata plus slot-aware HUD/service/OpenClaw read models

## Coexistence Rule

- Bash remains the default runtime for this phase.
- Elixir shares the same repo-local artifact contract and runtime-state shape.
- Running bash and Elixir as simultaneous active controllers for the same repo is unsupported.
- Bash `loop.sh` / legacy bash daemon and managed Elixir runs now participate in the same `.forgeloop/v2/active-runtime.json` claim file at run boundaries.
- Same-host dead claims now become reclaimable, while malformed ownership files stay visible and block new managed starts fail-closed.
- This still stops short of a full daemon-session lock or split-brain-prevention guarantee.

## Current Workflow-Pack Lane

The active workflow direction is an **experimental manual workflow lane** for native Forgeloop workflow packs, executed through a configured runner while preserving Forgeloop’s repo-local fail-closed contract.

Architecturally, that lane is intentionally narrow:

- it adds a third lane instead of refactoring all loop types into one executor
- it keeps `WORKFLOW.md` as a prompt/config surface rather than widening it into a graph manifest
- it leaves native graph execution deferred until the workflow-pack lane is proven
- it keeps the workflow lane focused on native Forgeloop workflow packs rather than alternate product identities

Elixir now routes manual workflow `preflight` / `run` actions through the same babysitter + disposable-worktree path used by other managed runs, while still delegating execution to the configured workflow runner. The loopback service, static UI, and OpenClaw seam all expose that same workflow control/status surface, and the workflow read model now includes catalog visibility, latest canonical artifacts, live active-run metadata, and a bounded workflow outcome/history sidecar. The experimental Elixir daemon can also honor one explicit `[WORKFLOW]` marker to launch a single configured workflow target through that same managed path, and the public `./forgeloop.sh daemon` command now prefers that managed backend while preserving `FORGELOOP_DAEMON_RUNTIME=bash` as explicit legacy fallback. Broader workflow orchestration and native graph execution remain future work.

See `docs/workflows.md` for the detailed operator contract.

## Current Self-Hosting Skeleton

With parser/read-path groundwork and repo-safe mutation helpers now in place, Elixir now has a manual runtime-isolation + operator-service skeleton:

1. sandboxed self-hosting via disposable git worktrees
2. a bounded single-child babysitter/supervisor above the child loop
3. canonical repo-root artifacts preserved while shell execution happens inside the disposable checkout
4. a loopback-only JSON control-plane service layered on top of the same file-first state
5. a bounded slot coordinator above that service for parallel read-class worktree runs (`plan` and workflow `preflight`) without widening the root fail-closed contract

That experimental slice preserves the same fail-closed artifact chain while making it possible to let Forgeloop work on Forgeloop inside a disposable worktree, expose the current state over a local service without introducing a second source of truth, and route Elixir-daemon checklist work through the same babysitter/worktree substrate. In phase 1, that service-backed backlog is still the implementation plan file, not a full native-Elixir planner replacement or tracker unification layer.

For the exact ship/no-ship checklist, see `v2-release-checklist.md`.

## Promotion Bar

### Alpha position now

Today’s claim should stay narrow and truthful:

- v2 is a **serious alpha** with a repeatable proof path
- v1 is still the stable/public recommendation
- v2 is suitable for demos, controlled evaluation, internal dogfooding, and project-by-project adoption where the team is deliberately evaluating the richer stack

### Beta promotion bar

Do **not** promote v2 to `v2.0.0-beta.1` until the checklist in `v2-release-checklist.md` is completed in one reviewed pass.

That includes:

1. daemon, service, and workflow public entrypoints are covered across repo-root and vendored layouts
2. shell, eval, Elixir, self-host proof, and screenshot regeneration all belong to a repeatable release-proof cadence
3. disposable-worktree cleanup, babysitter recovery, and watchdog behavior are explicit and green enough for release review
4. plugin seams such as OpenClaw have bounded smoke coverage rather than optimism-only documentation
5. parity/readiness/release docs all agree on what is landed, what is still experimental, and what remains deferred

### Prod-default bar

Do **not** make v2 the default public runtime until all of these are true:

1. the beta bar is already met
2. there is no unresolved safety-critical drift around fail-closed pauses, escalation artifacts, runtime-state semantics, provider failover, or layout portability
3. the managed daemon path has earned trust as the recommended path, not just the richer path
4. the bash fallback/rollback story is still explicit, safe, and boring
5. the cutover is an intentional release decision reflected in docs and upgrade guidance, not an accidental consequence of feature momentum

## Required Local Gates

```bash
bash tests/run.sh
bash evals/run.sh
cd elixir && mix test
# manual V2 alpha release proof
./forgeloop.sh self-host-proof
# reproducible public HUD screenshots
./bin/capture-product-screenshots.sh
```

## Explicit Deferrals

These are still out of scope for the current phase:

- Phoenix UI and dashboard work
- Broadway or any hot-path queue/pipeline
- Postgres-backed event storage
- event compaction/indexed search beyond the current bounded replay/tail API
- long-lived worktree orchestration beyond the current managed daemon launcher
- daemon-integrated UI/OpenClaw orchestration beyond the current shared coordination read model, bounded brief/timeline, single-window bounded OpenClaw playbook/apply seam, slot-aware read surfaces, and `[WORKFLOW]` request
- multi-slot write-class orchestration beyond the current read-slot coordinator (`build`, workflow `run`, promotion, queueing, and priorities)
- checkpoint-resume semantics and broader workflow orchestration beyond the current bounded history sidecar
- graph workflows
- exact checkpoint/resume
- multi-host workers
- tracker/`prd.json` backlog unification beyond the phase-1 implementation-plan surface
- raw or external tracker mutation tooling
- OpenClaw as a supported runtime/provider option today
