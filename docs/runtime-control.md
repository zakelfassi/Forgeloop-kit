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

In this first slice it is manual-only, backed by a configured workflow runner, not daemon-scheduled, and still bound to the same runtime-state + escalation contract as the other lanes.

See `docs/workflows.md` for the detailed workflow-lane contract and compatibility notes.

## Escalation artifact chain

When Forgeloop escalates:

1. `REQUESTS.md` gets `[PAUSE]`
2. `QUESTIONS.md` gets the blocking question / unresolved decision
3. `ESCALATIONS.md` gets a drafted handoff for the operator
4. `.forgeloop/runtime-state.json` becomes `awaiting-human`

This is the core fail-closed path for repeated failures and repeated unanswered blockers.

## Escalation modes

- `issue` — draft an issue-oriented handoff with a suggested `gh issue create ...` command
- `pr` — draft a PR-oriented handoff with a suggested `gh pr create ...` command
- `review` — draft a human-review handoff for an existing branch or PR
- `rerun` — draft a local rerun/resume command

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

## Planned isolation extension (not supported yet)

Today, the fail-closed contract is enforced in the canonical repo checkout.

The next planned self-hosting extension is to let a babysitter/supervisor launch bounded autonomous work inside a **disposable git worktree** while preserving the same repo-local artifact chain:

- `IMPLEMENTATION_PLAN.md`, `REQUESTS.md`, `QUESTIONS.md`, and `ESCALATIONS.md` remain the canonical coordination surface
- `.forgeloop/runtime-state.json` remains the machine-readable source of truth
- repeated failures and repeated unanswered blockers still pause and escalate instead of spinning

That planned worktree layer is meant to protect the canonical checkout from autonomous churn; it is **not** the primary security boundary. The VM/container remains that boundary.

The current `.forgeloop/v2/active-runtime.json` claim is also not yet worktree-aware or cross-runtime. It is only the current Elixir-side coexistence guard.

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
