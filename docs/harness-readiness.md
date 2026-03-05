# Harness Readiness

This repo is harness-ready when an agent can discover the rules, run the validations, and stop safely without hidden tribal knowledge.

## Required Properties

- Repo-local system of record:
  `AGENTS.md` stays short, while `docs/` holds the durable operating rules.
- Reproducible entrypoints:
  shell entrypoints behave the same in repo-root and vendored layouts.
- Deterministic validation:
  CI, verify, and smoke checks are executable from the repo and represented in tests.
- Mechanical backpressure:
  repeated failures pause the system and draft a human handoff.
- Garbage collection:
  stale PR stacks, stale plans, and dead operating docs are regularly collapsed or removed.

## Current Paved Paths

- `tests/run.sh` is the default shell test gate.
- `docs/runtime-control.md` defines the loop stop/escalation rules.
- `ESCALATIONS.md`, `QUESTIONS.md`, and `REQUESTS.md` form the human handoff surface.

## Next Gaps To Close

- Add more entrypoint smoke tests beyond the daemon.
- Add a small quality score review cadence so repo quality is measured, not guessed.
- Keep open PRs short-lived and rewrite stacked draft history into focused successors.
