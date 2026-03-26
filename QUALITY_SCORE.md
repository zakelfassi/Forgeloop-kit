# Quality Score

## Current Grade

`B`

## Upgrade Path To S-Tier

- `Path safety`: all runtime entrypoints resolve repo and kit roots correctly in every supported layout.
- `Backpressure`: repeated failures stop and escalate instead of looping indefinitely.
- `Harness coverage`: control-plane behaviors have regression tests, not just happy-path docs.
- `Repo hygiene`: stale PR stacks are rewritten into a few focused merge candidates.
- `Agent legibility`: durable runtime rules live in `docs/`, not in scattered prompt text.

## Current Evidence

- Shell gate: `bash tests/run.sh`
- Scenario harness: `bash evals/run.sh`
- Elixir gate: `cd elixir && mix test`
- Manual release proof: `./forgeloop.sh self-host-proof`
- Public layout smokes:
  - `tests/daemon-entrypoint-layouts.test.sh`
  - `tests/service-entrypoint-layouts.test.sh`
  - `tests/workflow-entrypoint-layouts.test.sh`

## Review Prompts

- Does the loop stop safely on repeated identical failures?
- Can a new operator find the control rules without reading the source first?
- Are the open PRs focused, mergeable, and giving signal instead of noise?
- Does CI catch repo-layout regressions before GitHub Actions becomes the first detector?
