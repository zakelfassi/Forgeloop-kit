# Workflow Lane (Experimental)

Forgeloop now has **three execution lanes**:

1. **Checklist lane** — `IMPLEMENTATION_PLAN.md` + `./forgeloop.sh plan|build`
2. **Tasks lane** — `prd.json` + `./forgeloop.sh tasks`
3. **Workflow lane (experimental)** — native workflow packs + `./forgeloop.sh workflow ...`

For phase-1 self-hosting, the checklist lane is the canonical backlog surfaced by the Elixir service/UI/OpenClaw seam. The tasks lane remains supported, but tracker/`prd.json` unification is intentionally deferred until after the UI core is stable.

This workflow lane is a **native Forgeloop capability**, but it still delegates execution to a configured workflow runner in this slice and remains intentionally narrow. Manual `preflight` / `run` actions route through the managed babysitter + disposable-worktree control-plane path rather than bypassing it, and the experimental Elixir daemon can now honor one explicit `[WORKFLOW]` marker to launch a single configured workflow target through that same path. Treat this document as the detailed contract; other README/docs/site surfaces should summarize and point here.

## What it is

The workflow lane lets Forgeloop run workflow packs while preserving the same repo-local runtime-state and fail-closed escalation contract as the other lanes.

Today it supports:

```bash
./forgeloop.sh workflow list
./forgeloop.sh workflow preflight <name>
./forgeloop.sh workflow run <name> [runner args...]
```

## Canonical repo layout

By default, Forgeloop looks for workflow packs in:

1. `workflows/`

You can override discovery with:

- `FORGELOOP_WORKFLOWS_DIR`

You can override runner selection with:

- `FORGELOOP_WORKFLOW_RUNNER`

A workflow pack is considered runnable only when it contains both:

- `workflow.dot`
- `workflow.toml`

## Runtime behavior

Workflow runs still write Forgeloop-owned state and artifacts:

- `.forgeloop/runtime-state.json`
- `.forgeloop/workflows/<name>/last-preflight.txt`
- `.forgeloop/workflows/<name>/last-run.txt`
- the normal escalation chain in `REQUESTS.md`, `QUESTIONS.md`, and `ESCALATIONS.md`

Runner state is exposed through:

- `FORGELOOP_WORKFLOW_STATE_ROOT`

That means repeated workflow failures still pause and escalate instead of spinning.

Elixir now exposes a managed control + visibility seam over this lane: workflow `preflight` / `run` actions flow through the babysitter/worktree/runtime-state path, the loopback JSON service and HUD/OpenClaw seam publish the same active-run/read-side view, and the repo-local tracker projection can map workflow packs into `Tracker.Issue`-shaped entries without widening the workflow execution contract yet.

## Current limitations

This lane is intentionally narrow in the current slice:

- manual workflow actions remain the default/operator-facing path
- the experimental Elixir daemon can trigger **one** workflow run per explicit `[WORKFLOW]` marker using `FORGELOOP_DAEMON_WORKFLOW_NAME` plus `FORGELOOP_DAEMON_WORKFLOW_ACTION`
- `[WORKFLOW]` is consumed only after the managed run actually starts, and build/replan work still takes precedence over queued workflow requests
- the public daemon honors `[WORKFLOW]` only when the managed backend is active; `FORGELOOP_DAEMON_RUNTIME=bash` keeps the legacy daemon path that ignores it
- it wraps a **configured workflow runner** rather than interpreting `workflow.dot` natively
- concurrent use with build/tasks/daemon is unsupported in this slice
- workflow status is currently limited to active-run metadata plus canonical `last-preflight.txt` / `last-run.txt` artifacts; richer outcome/history remains future work
- `WORKFLOW.md` remains a separate prompt/config surface in Elixir and is **not** widened to absorb graph workflow manifests
- future tracker/task/backlog projection must stay outside `WORKFLOW.md` service-owned keys

## Checkpoint cadence

We want workflow-pack work to ship in small, reviewable atoms.

### Per-slice rule
Each workflow slice should end with one scoped checkpoint commit after:

- `bash tests/run.sh`
- `bash evals/run.sh`
- `cd elixir && mix test`
- README / docs / site copy are updated

### Scope rule
Do not mix these in one checkpoint commit:

- workflow lane behavior
- unrelated prompt/skill/site cleanup
- daemon scheduling changes
- native graph execution experiments

### Suggested naming

- `workflow-slice-01: add workflow pack lane`
- `workflow-slice-02: add read-only workflow visibility service`
- `workflow-slice-03: route workflow packs through managed control plane`

## Future direction

The workflow lane is an execution seam, not the endpoint.

Planned future work includes:

- broader workflow orchestration beyond the current one-shot Elixir-daemon `[WORKFLOW]` request
- richer workflow outcome/history and checkpoint semantics on top of the current active-run + artifact view
- OpenClaw monitoring/piloting of the loop and the babysitter beyond the current manual control surface
- deciding whether native graph execution belongs inside Forgeloop or remains delegated to a workflow runner
