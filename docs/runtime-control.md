# Runtime Control

Forgeloop should fail closed, not spin.

## Control Rules

- Repeated identical verify or CI failures are tracked across iterations.
- After `FORGELOOP_FAILURE_ESCALATE_AFTER` identical failures, the active loop stops.
- Stopping drafts a human handoff in `ESCALATIONS.md`, appends a question to `QUESTIONS.md`, and adds `[PAUSE]` to `REQUESTS.md`.
- The daemon remains paused until a human removes `[PAUSE]` and resolves the pending question.
- The current runtime state is written to `.forgeloop/runtime-state.json`.
- `runtime-state.json` in `.forgeloop/` is the machine-readable source of truth for the current loop/daemon state.

## Escalation Modes

- `issue`: draft an issue-oriented handoff with a suggested `gh issue create ...` command.
- `pr`: draft a PR-oriented handoff with a suggested `gh pr create ...` command.
- `review`: draft a human-review handoff for an existing branch or PR.
- `rerun`: draft a local rerun/resume command.

## Invariants

- Path resolution must work in both repo-root and vendored `repo/forgeloop` layouts.
- A loop may retry transient failures, but it must not retry indefinitely without a state transition.
- Human escalation artifacts live in repo-local files so the operator can inspect them without external services.

## Runtime States

- `running`: an active plan/build/tasks/daemon pass is in progress.
- `blocked`: Forgeloop hit a repeatable failure but has not crossed the escalation threshold yet.
- `paused`: the daemon is paused by explicit operator request.
- `awaiting-human`: Forgeloop paused itself and is waiting for operator input.
- `recovered`: a paused/blocked state was cleared and the loop resumed cleanly.
- `idle`: nothing is actively running.

## Scenario Harness

Run the built-in control-plane scenarios with:

```bash
./forgeloop.sh evals
```
- Runtime state must be explicit enough for tooling to distinguish `building`, `retrying`, `paused`, `awaiting-human`, `idle`, and `complete`.
