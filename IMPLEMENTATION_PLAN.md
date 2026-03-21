# Implementation Plan

This file is the prioritized backlog Forgeloop works from.

Goal: make Forgeloop progressively able to build itself from repo-local specs/plans/tasks, with a repo-local UI becoming the primary human coordination surface instead of GitHub-issue-centric workflows.

Guiding constraints:
- Bash remains the public acceptance anchor for now.
- Elixir remains additive and owns the growing v2 control plane.
- Repo-local files stay canonical: `IMPLEMENTATION_PLAN.md`, `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, and `.forgeloop/runtime-state.json`.
- Phase 1 UI is loopback-only and lightweight; no required DB, Phoenix, or Node pipeline.
- The UI may become the primary operator surface, but it must preserve the file-first fail-closed contract.

Format:
- [ ] Pending item
- [x] Completed item (keep this section trimmed)
- Under each item, keep acceptance and required tests explicit.

## Next Up

- [x] Add an experimental native workflow-pack lane through Forgeloop’s fail-closed runtime contract
  - Acceptance:
    - `./forgeloop.sh workflow list|preflight|run` exists and wraps a configured workflow runner.
    - Workflow runs write Forgeloop runtime state and evidence files, and repeated failures escalate through the existing artifact chain.
    - Elixir exposes workflow package discovery through a separate catalog seam without widening `WORKFLOW.md` semantics.
    - `README.md`, `docs/workflows.md`, `docs/runtime-control.md`, `docs/v2-roadmap.md`, and `index.html` all describe the workflow lane as native/manual in the same terms.
  - REQUIRED TESTS:
    - `tests/workflow-lane.test.sh`
    - `elixir/test/forgeloop_v2/workflow_catalog_test.exs`
    - `elixir/test/forgeloop_v2/workflow_test.exs`
    - existing install output + shell/eval gates stay green
  - Follow-on shipped in the same track:
    - read-only Elixir workflow visibility service over workflow catalogs + latest preflight/run artifacts
  - Deferred after this slice:
    - embedded service/API workflow surfaces
    - worktree-aware babysitter/supervisor integration
    - native graph execution
    - OpenClaw/plugin seam work

- [x] Add repo-safe mutation helpers for questions and control flags, including file-level locking for parse-modify-write operations
  - Acceptance:
    - Answering or resolving a question updates only the targeted question section.
    - Adding/clearing `[PAUSE]` and `[REPLAN]` remains idempotent.
    - Concurrent UI/operator writes do not clobber escalation appends from the runtime.
  - REQUIRED TESTS:
    - idempotent re-answer test
    - conflicting-answer returns conflict error
    - lock-timeout/error paths leave source files unchanged
    - existing escalation tests stay green
  - Shipped behavior:
    - section-level question answer/resolve with optimistic concurrency tokens
    - locked idempotent `[PAUSE]` / `[REPLAN]` mutation helpers
    - question/flag edits do not themselves write `recovered`

## Backlog

- [x] Add sandboxed self-hosting via disposable git worktrees and a babysitter/supervisor operating mode
  - Acceptance:
    - Docs and code define disposable worktrees as repo-internal isolation for autonomous runs, not the primary security boundary.
    - A babysitter/supervisor owns child-run lifecycle, heartbeat/watchdog behavior, and worktree cleanup without changing the current fail-closed artifact chain.
    - Repo-root artifacts (`IMPLEMENTATION_PLAN.md`, `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, `.forgeloop/runtime-state.json`) remain canonical even when autonomous work runs in a disposable worktree.
    - `.forgeloop/v2/active-runtime.json` semantics are updated deliberately if worktree-aware ownership lands; until then the docs stay explicit about current limits.
  - REQUIRED TESTS:
    - disposable worktree lifecycle smoke test
    - babysitter pause/resume/kill test
    - self-hosted run still writes canonical runtime-state + escalation artifacts
    - dirty-tree and crash-recovery cleanup tests
  - Shipped behavior:
    - `ForgeloopV2.Worktree` creates/cleans disposable git worktrees under `.forgeloop/v2/workspaces`
    - `ForgeloopV2.Babysitter` runs a single child loop in that checkout, writes heartbeat metadata under `.forgeloop/v2/babysitter`, and can stop/pause canonically
    - `ShellLoop` can execute from a disposable checkout while keeping runtime/control artifacts pointed at canonical repo-root files
  - Deferred after this slice:
    - daemon scheduling through the babysitter
    - loopback service/UI surfaces on top of babysitter snapshots
    - workflow-lane babysitting
    - OpenClaw/plugin seam work

- [ ] Define a plugin/integration seam for future OpenClaw support
  - Acceptance:
    - OpenClaw is documented as future integration work, not a current provider/runtime option.
    - The implementation path is explicit about the formal integration seam we choose, and it preserves the same repo-local fail-closed contract.
    - Existing workflow/config validation stays truthful: no unsupported `providers` or `runtime` keys are introduced in phase 1.
    - Any future OpenClaw integration exposes Forgeloop actions through a bounded, reviewable surface instead of ad hoc shell glue.
  - REQUIRED TESTS:
    - integration seam contract validation test
    - OpenClaw-triggered action still writes canonical control artifacts
    - unsupported config stays rejected until the seam actually lands

- [ ] Extend `ForgeloopV2.Events` with replay/tail/subscribe behavior and add operator event types
  - Acceptance:
    - JSONL remains the durable source of truth.
    - Subscribers receive new daemon/loop/operator events.
    - New operator events are persisted and streamable.
  - REQUIRED TESTS:
    - event subscription test
    - replay/tail ordering test
    - existing event tests stay green

- [x] Add an embedded Elixir service mode with a control-plane GenServer and loopback-only HTTP API
  - Acceptance:
    - `mix forgeloop_v2.serve --repo ..` starts a local loopback service exposing runtime, backlog, questions, escalations, events, workflow visibility, and babysitter state.
    - Manual `plan`/`build` requests now flow through the service-managed babysitter (`/api/babysitter/start`) and still reuse `Loop.run/3` while rejecting concurrent runs cleanly.
    - Pause requests can write paused runtime state through an operator writer without changing recovery semantics.
  - REQUIRED TESTS:
    - service/control-plane tests
    - busy/manual-run serialization tests
    - operator-writer runtime transition tests
  - Shipped behavior:
    - `ForgeloopV2.ControlPlane` serializes loopback operator actions over the existing file-first control plane.
    - `ForgeloopV2.Service` exposes local JSON endpoints for runtime, backlog, questions, escalations, events, workflows, provider health, and babysitter start/stop/status.
    - The service now also serves a static loopback-only UI at `/` with SSE-backed live snapshots over the same file-first control plane.
  - Deferred after this slice:
    - direct UI-triggered `surface: "ui"` one-off runs separate from the babysitter path

- [x] Ship a static repo-local UI for runtime status, backlog, questions, escalations, events, and provider health
  - Acceptance:
    - A local operator can open the UI and see the same repo-local state visible in markdown/json files.
    - Event updates appear live when the daemon or loop runs.
    - The UI works without Phoenix, a database, or a Node asset pipeline.
  - REQUIRED TESTS:
    - HTTP smoke test for static assets and bootstrap JSON
    - SSE/browser smoke test for live updates
    - repo-root and vendored layout startup both work
  - Shipped behavior:
    - `ForgeloopV2.Service` now serves `/`, `/assets/app.css`, and `/assets/app.js` directly from `elixir/priv/static/ui` without Phoenix or a Node pipeline.
    - `/api/stream` publishes full-snapshot SSE updates over the existing `ControlPlane.overview/2` read model.
    - `ForgeloopV2.ProviderHealth` derives provider badges from `providers-state.json` plus provider events without introducing a new store.
    - Installed repos now get `./forgeloop.sh serve` as the one-command launcher for the local operator UI.

- [ ] Add interactive UI flows for answering questions, resolving questions, pausing, clearing pause, requesting replan, and triggering one-off `plan` / `build` runs
  - Acceptance:
    - Answering a question updates `QUESTIONS.md` and leaves recovery to the next daemon/loop cycle.
    - Clearing pause removes `[PAUSE]` without falsely writing `recovered`.
    - One-off plan/build runs use `surface: "ui"` but preserve the existing runtime-state and escalation contract.
  - REQUIRED TESTS:
    - question-answer affects next recovery decision
    - clear-pause followed by daemon tick preserves recovered->idle/running semantics
    - UI-triggered build failures still escalate through the existing failure tracker/artifact chain

- [ ] Make the UI the primary human coordination surface in docs and escalation copy while keeping repo-local files canonical
  - Acceptance:
    - `README.md`, `docs/runtime-control.md`, `docs/v2-roadmap.md`, `docs/elixir-parity-matrix.md`, and `elixir/README.md` consistently describe the UI as additive and repo-local.
    - Escalation artifacts point operators to the local UI/serve command first; GitHub-oriented commands become optional secondary follow-up.
    - Prompts/templates preserve the file-first contract while acknowledging the UI surface.
  - REQUIRED TESTS:
    - escalation artifact copy tests
    - bash/eval anchors remain green after wording/template changes

- [ ] Make `IMPLEMENTATION_PLAN.md` the explicit phase-1 canonical backlog for self-hosting, and defer `prd.json` / tracker unification until after the UI core is stable
  - Acceptance:
    - `IMPLEMENTATION_PLAN.md` is documented and exposed as the canonical backlog in phase 1.
    - Future repo-local tracker/task-lane integration has a defined seam and does not require changing `WORKFLOW.md` service-owned-key rules.
    - The self-hosting story is documented without claiming a full native-Elixir planner replacement yet.
  - REQUIRED TESTS:
    - `Orchestrator` and service backlog endpoints report the same pending-work answer for the same plan file
    - workflow forbidden-key protections stay green

## Later / Strategic

- [ ] Add a repo-local tracker adapter (for example `ForgeloopV2.Tracker.RepoLocal`) that projects plan/task state into `Tracker.Issue` structs
- [ ] Decide whether `prd.json` becomes a first-class alternate work lane in the UI
- [ ] Decide whether bash should participate in `.forgeloop/v2/active-runtime.json` before making stronger split-brain-prevention claims
- [ ] Reassess whether a richer multi-user/dashboard architecture is warranted after the local UI loop is proven

## Checkpoint Cadence

- [ ] Ship one scoped checkpoint commit whenever a slice lands with tests/docs green
  - Rules:
    - one feature slice per checkpoint commit
    - do not mix workflow-lane behavior with unrelated cleanup
    - update `README.md` and `index.html` in the same slice when public behavior changes
  - Suggested naming:
    - `workflow-slice-01: add workflow pack lane`
      - `workflow-slice-02: add read-only workflow visibility service`
      - `workflow-slice-03: add workflow service/ui surfaces`

## Skill Opportunities

- [ ] Forge `repo-local-coordination-regression` to run file + runtime-state + event-log + API regression checks for control-plane/UI changes
- [ ] Forge `implementation-plan-curator` to keep this plan deduplicated, prioritized, and aligned with required tests
- [ ] Forge `ui-proof-loop` to start the service, trigger one action, watch SSE, and verify files + gates end-to-end

## Validation Gates

- [ ] `bash tests/run.sh`
- [ ] `bash evals/run.sh`
- [ ] `cd elixir && mix test`
