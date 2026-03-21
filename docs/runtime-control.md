# Runtime Control

Forgeloop should **fail closed, not spin**.

This document is the operator contract for what the runtime actually does today.

## Core safety rule

When Forgeloop hits the same failure or blocker repeatedly, it should stop the loop, preserve state, and ask for a human decision instead of retrying forever.

## Supported daemon control flags

The daemon is **interval-based** (`./forgeloop.sh daemon 300` polls every 300 seconds by default).

It supports these flags in `REQUESTS.md`:

- `[PAUSE]` — pause the daemon until the flag is removed
- `[REPLAN]` — run a planning pass before continuing build work

These flags are treated as standalone marker lines in `REQUESTS.md`, and add/clear operations are idempotent on the Elixir control plane.
- `[DEPLOY]` — run `FORGELOOP_DEPLOY_CMD`, if configured
- `[INGEST_LOGS]` — run log ingestion using `FORGELOOP_INGEST_LOGS_CMD` or `FORGELOOP_INGEST_LOGS_FILE`

There is **no** daemon-side `[KNOWLEDGE_SYNC]` flag.
There is also **no** daemon-side `[WORKFLOW]` flag in this slice; workflow runs are manual-only.

## Manual workflow lane (experimental)

Forgeloop now has an experimental manual workflow lane:

```bash
./forgeloop.sh workflow list
./forgeloop.sh workflow preflight <name>
./forgeloop.sh workflow run <name> [runner args...]
```

In this first slice it is manual-only, backed by a configured workflow runner, not daemon-scheduled, and still bound to the same runtime-state + escalation contract as the other lanes. Elixir can now read workflow catalogs plus the latest workflow artifacts through a read-only control-plane seam.

See `docs/workflows.md` for the detailed workflow-lane contract and compatibility notes.

## Escalation artifact chain

When Forgeloop escalates:

1. `REQUESTS.md` gets `[PAUSE]`
2. `QUESTIONS.md` gets the blocking question / unresolved decision
3. `ESCALATIONS.md` gets a drafted handoff for the operator
4. `.forgeloop/runtime-state.json` becomes `awaiting-human`

This is the core fail-closed path for repeated failures and repeated unanswered blockers.

Answering or resolving a question in `QUESTIONS.md` does not itself write `recovered`; recovery is still decided by the next daemon/loop cycle.

## Escalation modes

- `issue` — draft a HUD-first handoff that optionally suggests `gh issue create ...` as follow-up
- `pr` — draft a HUD-first handoff that optionally suggests `gh pr create ...` as follow-up
- `review` — draft a HUD-first human-review handoff for an existing branch or PR
- `rerun` — draft a HUD-first local rerun/resume handoff

## Runtime state model

`.forgeloop/runtime-state.json` is the machine-readable source of truth.

It uses:

- `status` — coarse operator state
- `transition` — detailed lifecycle transition
- `surface` — which runtime surface wrote the state (`loop`, `daemon`, etc.)
- `mode` — which mode is active (`build`, `plan`, `tasks`, `daemon`, etc.)
- `requested_action` — the drafted escalation action when relevant

### Status values

- `running` — active loop/daemon work is in progress
- `blocked` — Forgeloop hit a repeatable failure but has not escalated yet
- `paused` — the daemon is paused by explicit operator request
- `awaiting-human` — Forgeloop paused itself and is waiting for input
- `recovered` — a paused/blocked state was cleared and the runtime resumed
- `idle` — nothing is actively running

### Transition examples

Transitions retain more detail than `status`, for example:

- `planning`
- `building`
- `retrying`
- `blocked`
- `escalated`
- `resuming`
- `completed`

That means a runtime state can legitimately look like:

```json
{
  "status": "blocked",
  "transition": "retrying",
  "surface": "loop",
  "mode": "build",
  "requested_action": "",
  "reason": "Repeated CI failure"
}
```

## Invariants

- Path resolution must work in both repo-root and vendored `repo/forgeloop` layouts
- A loop may retry transient failures, but it must not retry indefinitely without a state transition
- Human escalation artifacts live in repo-local files so the operator can inspect them without external services
- Full-auto mode should assume the VM/container is the security boundary

## Manual disposable-worktree babysitter (experimental Elixir v2)

Today, the fail-closed contract is still anchored in the canonical repo checkout, but Elixir now has a **manual experimental babysitter** that can launch one child `plan` or `build` run inside a **disposable git worktree**.

```bash
cd elixir
mix forgeloop_v2.babysit build --repo ..
```

That babysitter keeps the same repo-local artifact chain canonical at repo root:

- `IMPLEMENTATION_PLAN.md`, `REQUESTS.md`, `QUESTIONS.md`, and `ESCALATIONS.md` remain the coordination surface
- `.forgeloop/runtime-state.json` remains the machine-readable source of truth
- repeated failures and repeated unanswered blockers still pause and escalate instead of spinning

It also writes worktree/heartbeat metadata under `.forgeloop/v2/babysitter/` and cleans stale disposable checkouts on the next babysitter start.

This worktree layer is a repo-internal hygiene boundary, **not** the primary security boundary. The VM/container remains that boundary.

Important current limits:

- the bash daemon does **not** schedule babysitter runs yet
- the workflow lane is still manual-only and is not yet babysat through this path
- the current `.forgeloop/v2/active-runtime.json` claim is still not worktree-aware or cross-runtime; it remains the current Elixir-side coexistence guard

## Loopback JSON control-plane service (experimental Elixir v2)

Elixir now also ships a loopback-only service layer:

```bash
cd elixir
mix forgeloop_v2.serve --repo ..
```

That service reuses the same file-first control plane rather than introducing a second state store. It now also serves a static operator UI at the service root, and today exposes:

- runtime state
- the phase-1 canonical backlog from `FORGELOOP_IMPLEMENTATION_PLAN_FILE` (default `IMPLEMENTATION_PLAN.md`)
- questions and escalations
- recent JSONL events
- workflow visibility snapshots
- provider health derived from the existing provider-state file + provider events
- babysitter status plus manual babysitter `plan` / `build` start/stop
- a live SSE snapshot stream for browser updates
- interactive UI controls for pause, clear-pause, replan, question answer/resolve, and one-off `plan` / `build`

Operator mutations still go through the same helpers and runtime-state transitions:

- pause requests append `[PAUSE]` and may write `paused` through the service writer only when no other runtime is already marked `running`
- clear-pause requests remove `[PAUSE]` without writing `recovered`; the next daemon/loop cycle still owns recovery
- replan requests append `[REPLAN]`
- question answer / resolve requests still update `QUESTIONS.md` without faking `recovered`
- manual UI runs still flow through `Loop.run/3` via the babysitter path instead of a new executor, and record `surface: "ui"`
- the repo now also ships an OpenClaw workspace plugin seam at `.openclaw/extensions/forgeloop/`; manual runs launched there record `surface: "openclaw"`
- in phase 1, backlog visibility resolves from the configured implementation plan file rather than a unified tracker/tasks abstraction
- canonical repo files and the existing JSON endpoints remain authoritative

Still intentionally deferred here:

- daemon-integrated babysitter scheduling
- workflow-lane babysitting
- remote/multi-host OpenClaw orchestration beyond the same-host loopback model

## Proof suite

Run the public safe-autonomy proof suite with:

```bash
./forgeloop.sh evals
```

That suite is curated to demonstrate:

- daemon pause behavior
- repeated-failure escalation
- runtime-state transitions
- blocker escalation
- auth failover
- entrypoint portability

## Experimental Elixir parity layer

The repo now also contains an experimental `elixir/` foundation that preserves the same operator-facing artifacts and `.forgeloop/runtime-state.json` contract for the phase-1 safety nucleus.

For now, deploy/log-ingest orchestration, tracker integration, and the rest of the planned Phoenix service remain future work; the bash runtime is still the default operational path.

The current coexistence rule is intentionally narrow:

- bash remains the default runtime
- Elixir is opt-in and experimental
- simultaneous bash and Elixir active control of one repo is unsupported for this phase
- Elixir records its active-runtime claim under `.forgeloop/v2/active-runtime.json`
- Elixir stops when that file already names a different owner at claim time
- this is an Elixir-side coexistence guard, not a full cross-runtime lock or split-brain-prevention guarantee
