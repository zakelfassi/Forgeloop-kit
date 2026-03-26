# Quality Score

## Current Grade

`B+`

## Current Posture

- **v1.0.0** is still the production/stable track.
- **`main` / v2** is now a **serious alpha**: the shell gate, eval harness, Elixir suite, self-host proof, public entrypoint smokes, and reproducible product screenshots are all part of the release story.
- It is **not beta yet** and **not ready to become the default runtime** yet.

## Promotion Rubric

### Alpha-ready now

Alpha is credible when all of these stay true:

- shell regressions pass via `bash tests/run.sh`
- fail-closed runtime scenarios pass via `bash evals/run.sh`
- Elixir service/UI/worktree tests pass via `cd elixir && mix test`
- the real HUD/service path passes via `./forgeloop.sh self-host-proof`
- public screenshots regenerate from canonical loopback state via `./bin/capture-product-screenshots.sh`
- public docs describe the current risk posture honestly

### Beta gate

Do **not** call v2 beta until all of these are true:

- public entrypoint smokes stay green across repo-root and vendored layouts for daemon, service, and workflow paths
- the alpha proof cadence stays green enough that release-review evidence is fresh, not one-off theater
- disposable-worktree cleanup and babysitter recovery/watchdog checks are explicit and green
- the OpenClaw/plugin seam has bounded smoke coverage, not just prose confidence
- `docs/harness-readiness.md`, `docs/release-tracks.md`, `docs/v2-roadmap.md`, and `docs/elixir-parity-matrix.md` all reflect the same truth about what is landed and what is still deferred

### Prod-default gate

Do **not** make v2 the default public runtime until all of these are true:

- the beta gate is met first
- bash and Elixir coexistence/fallback guidance is stable enough that rollback is boring and reviewable
- no unresolved safety-critical parity gap remains around fail-closed pauses, escalation artifacts, runtime-state semantics, provider failover, or layout portability
- the managed daemon path has earned trust as the recommended path, not just the richer path
- the stable-v1 fallback story remains documented until the cutover is intentionally changed

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
- Are the release-track docs and the code/test reality saying the same thing?
- If the managed daemon path regressed tomorrow, would the bash fallback story still be obvious and safe?
