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

- [ ] Add structured repo-local parsers for `IMPLEMENTATION_PLAN.md`, `QUESTIONS.md`, and `ESCALATIONS.md`, and route existing daemon logic through them
  - Acceptance:
    - `Orchestrator` no longer uses a raw regex to detect pending plan work.
    - Unanswered question detection is derived from a shared parser that distinguishes awaiting, answered, and resolved states.
    - Existing markdown file formats remain readable without migration.
  - REQUIRED TESTS:
    - `elixir/test/forgeloop_v2/plan_store_test.exs`
    - `elixir/test/forgeloop_v2/coordination_test.exs`
    - existing `orchestrator_test.exs`, `daemon_test.exs`, blocker/recovery tests stay green

- [ ] Add repo-safe mutation helpers for questions and control flags, including file-level locking for parse-modify-write operations
  - Acceptance:
    - Answering or resolving a question updates only the targeted question section.
    - Adding/clearing `[PAUSE]` and `[REPLAN]` remains idempotent.
    - Concurrent UI/operator writes do not clobber escalation appends from the runtime.
  - REQUIRED TESTS:
    - idempotent re-answer test
    - conflicting-answer returns conflict error
    - lock-timeout/error paths leave source files unchanged
    - existing escalation tests stay green

## Backlog

- [ ] Extend `ForgeloopV2.Events` with replay/tail/subscribe behavior and add operator event types
  - Acceptance:
    - JSONL remains the durable source of truth.
    - Subscribers receive new daemon/loop/operator events.
    - New operator events are persisted and streamable.
  - REQUIRED TESTS:
    - event subscription test
    - replay/tail ordering test
    - existing event tests stay green

- [ ] Add an embedded Elixir service mode with a control-plane GenServer and loopback-only HTTP API
  - Acceptance:
    - `mix forgeloop_v2.serve --repo ..` starts a local service exposing runtime, backlog, questions, escalations, and events.
    - Manual `plan`/`build` requests reuse `Loop.run/3` and reject concurrent execution cleanly.
    - Pause requests can write paused runtime state through an operator writer without changing recovery semantics.
  - REQUIRED TESTS:
    - service/control-plane tests
    - busy/manual-run serialization tests
    - operator-writer runtime transition tests

- [ ] Ship a static repo-local UI for runtime status, backlog, questions, escalations, events, and provider health
  - Acceptance:
    - A local operator can open the UI and see the same repo-local state visible in markdown/json files.
    - Event updates appear live when the daemon or loop runs.
    - The UI works without Phoenix, a database, or a Node asset pipeline.
  - REQUIRED TESTS:
    - HTTP smoke test for static assets and bootstrap JSON
    - SSE/browser smoke test for live updates
    - repo-root and vendored layout startup both work

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

## Skill Opportunities

- [ ] Forge `repo-local-coordination-regression` to run file + runtime-state + event-log + API regression checks for control-plane/UI changes
- [ ] Forge `implementation-plan-curator` to keep this plan deduplicated, prioritized, and aligned with required tests
- [ ] Forge `ui-proof-loop` to start the service, trigger one action, watch SSE, and verify files + gates end-to-end

## Validation Gates

- [ ] `bash tests/run.sh`
- [ ] `bash evals/run.sh`
- [ ] `cd elixir && mix test`
