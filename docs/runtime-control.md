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
- `[DEPLOY]` — run the deploy lifecycle, if configured
- `[INGEST_LOGS]` — run log ingestion using `FORGELOOP_INGEST_LOGS_CMD` or `FORGELOOP_INGEST_LOGS_FILE`

There is **no** daemon-side `[KNOWLEDGE_SYNC]` flag.

### Deploy lifecycle

`[DEPLOY]` now runs up to three explicit stages:

1. `FORGELOOP_DEPLOY_PRE_CMD` — optional deploy preparation such as artifact builds or database migrations
2. `FORGELOOP_DEPLOY_CMD` — the actual restart, rollout, or release step
3. `FORGELOOP_DEPLOY_SMOKE_CMD` — optional post-deploy smoke checks

If a deploy stage fails, Forgeloop records the failure and uses the same repeated-failure backpressure path as other runtime failures.

## Verify command safety

`FORGELOOP_VERIFY_CMD` is for validation only.

- Good examples: typecheck, tests, lint, build
- Bad examples: `systemctl restart`, `docker compose up`, `kubectl rollout restart`

By default, Forgeloop rejects deploy-like verify commands so deployment side effects do not get hidden inside a "verify passed" message.

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
Forgeloop keeps the runtime directory private (`0700`) and rewrites the state file as owner-only (`0600`) on each update.

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
