# Quality Score

## Current Grade

`B`

## Upgrade Path To S-Tier

- `Path safety`: all runtime entrypoints resolve repo and kit roots correctly in every supported layout.
- `Backpressure`: repeated failures stop and escalate instead of looping indefinitely.
- `Harness coverage`: control-plane behaviors have regression tests, not just happy-path docs.
- `Release-proof cadence`: shell, eval, Elixir, self-host proof, and product screenshot regeneration happen on a repeatable alpha-proof rhythm instead of ad hoc demos.
- `Repo hygiene`: stale PR stacks are rewritten into a few focused merge candidates.
- `Agent legibility`: durable runtime rules live in `docs/`, not in scattered prompt text.

## Current Evidence

- Shell gate: `bash tests/run.sh`
- Scenario harness: `bash evals/run.sh`
- Elixir gate: `cd elixir && mix test`
- Manual release proof: `./forgeloop.sh self-host-proof`
- Screenshot regeneration: `./bin/capture-product-screenshots.sh`
- Public layout smokes:
  - `tests/daemon-entrypoint-layouts.test.sh`
  - `tests/service-entrypoint-layouts.test.sh`
  - `tests/workflow-entrypoint-layouts.test.sh`
- Alpha proof workflow:
  - `.github/workflows/v2-alpha-proof.yml`

## Review Prompts

- Does the loop stop safely on repeated identical failures?
- Can a new operator find the control rules without reading the source first?
- Can we regenerate the public screenshots and proof artifacts from real loopback state instead of mocked demos?
- Are the open PRs focused, mergeable, and giving signal instead of noise?
- Does CI catch repo-layout regressions before GitHub Actions becomes the first detector?
