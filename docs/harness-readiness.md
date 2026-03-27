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
- `./forgeloop.sh self-host-proof` is the manual v2-beta HUD/service proof for bounded self-hosting checks.
- `.github/workflows/v2-beta-proof.yml` is the manual/scheduled beta proof cadence for shell, eval, Elixir, self-host, and screenshot regeneration.
- `./bin/capture-product-screenshots.sh` regenerates the committed public screenshots from a seeded canonical demo repo instead of mocked UI states.
- `tests/openclaw-plugin.test.sh` and `tests/openclaw-loopback-smoke.test.sh` keep the OpenClaw seam honest at both the contract and real loopback-integration layers, including slot list/start/detail/stop over loopback HTTP.
- `docs/runtime-control.md` defines the loop stop/escalation rules.
- `ESCALATIONS.md`, `QUESTIONS.md`, and `REQUESTS.md` form the human handoff surface.
- `.forgeloop/runtime-state.json` is the machine-readable runtime state surface.
- `.forgeloop/v2/slots/<slot-id>/...` now carries slot-scoped runtime and coordination evidence for the experimental multi-slot surface: parallel read slots stay slot-local, while the single active write slot still preserves canonical repo-root coordination files.

## What Harness-Ready Means Today

- **Harness-ready is not the same as prod-default.**
- Today, the repo is strong enough to support a real **v2 beta release loop**: shell gate, evals, Elixir tests, self-host proof, and screenshot regeneration are all codified.
- The harness is **not** yet saying “make v2 the default runtime.” It is saying “the beta stack now has a repeatable proof path.”
- For the actual release call and checklist, use `v2-release-checklist.md`.

## Prod-Default Gaps To Close

To keep the beta trustworthy, continue doing all of the following:

- keep the public entrypoint smoke tests green across repo-root and vendored layouts
- keep the beta proof workflow and screenshot regeneration path fresh enough for release review
- keep disposable-worktree cleanliness and cleanup checks green as the babysitter grows
- keep daemon-integrated babysitter child-run recovery and watchdog checks green as the managed path evolves
- keep the loopback self-host proof stable across clean and dirty source checkouts
- keep integration-surface smoke tests for plugin seams such as OpenClaw green as the control plane evolves
- keep slot-aware service/HUD/OpenClaw proofs green as the bounded multi-slot coordinator evolves
- keep the parity/readiness docs precise as landed behavior evolves

Before making v2 the **prod-default** path:

- meet the beta gate first
- keep the bash fallback path explicit and boring
- prove there is no unresolved safety-critical drift between bash authority and managed Elixir behavior
- make the default-runtime recommendation an intentional release decision, not an accidental shift caused by momentum
