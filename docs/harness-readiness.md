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
- `tests/daemon-entrypoint-layouts.test.sh`, `tests/service-entrypoint-layouts.test.sh`, and `tests/workflow-entrypoint-layouts.test.sh` keep public entrypoints honest across repo-root and vendored layouts.
- `evals/run.sh` is the scenario harness for runtime-state and pause/escalation behavior.
- `./forgeloop.sh self-host-proof` is the manual v2-alpha HUD/service proof for bounded self-hosting checks.
- `.github/workflows/v2-alpha-proof.yml` is the manual/scheduled alpha proof cadence for shell, eval, Elixir, self-host, and screenshot regeneration.
- `./bin/capture-product-screenshots.sh` regenerates the committed public screenshots from a seeded canonical demo repo instead of mocked UI states.
- `docs/runtime-control.md` defines the loop stop/escalation rules.
- `ESCALATIONS.md`, `QUESTIONS.md`, and `REQUESTS.md` form the human handoff surface.
- `.forgeloop/runtime-state.json` is the machine-readable runtime state surface.

## Next Gaps To Close

- Keep the public entrypoint smoke tests green across repo-root and vendored layouts, and widen that posture to additional public surfaces only when the proof pays for itself.
- Keep the alpha proof workflow and screenshot regeneration path green enough that release-review evidence stays fresh instead of turning into once-run theater.
- Keep open PRs short-lived and rewrite stacked draft history into focused successors.
- Keep disposable-worktree cleanliness and cleanup checks green as the babysitter grows.
- Add daemon-integrated babysitter child-run recovery and watchdog checks.
- Keep the new loopback self-host proof stable across clean and dirty source checkouts.
- Add integration-surface smoke tests for future plugin seams such as OpenClaw.
