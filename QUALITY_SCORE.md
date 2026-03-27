# Quality Score

## Current Grade

`A-`

## Current Posture

- **v1.0.0** is still the production/stable track.
- **`main` / v2** is now a **beta track**: the shell gate, eval harness, Elixir suite, self-host proof, public entrypoint smokes, and reproducible product screenshots are all part of the release story.
- It is **not** ready to become the default runtime yet.

## Release Scoreboard

| Area | Status | Notes |
| --- | --- | --- |
| Shell gate | ✅ | `bash tests/run.sh` |
| Scenario harness | ✅ | `bash evals/run.sh` |
| Elixir suite | ✅ | `cd elixir && mix test` |
| Self-host proof | ✅ | `./forgeloop.sh self-host-proof` |
| Screenshot regeneration | ✅ | `./bin/capture-product-screenshots.sh` |
| Public entrypoint smokes | ✅ | daemon, service, and workflow layout smokes are landed |
| OpenClaw seam | ✅ | contract test + real loopback smoke are landed |
| Babysitter recovery proof | ✅ | stale cleanup / daemon recovery proof is landed |
| Docs alignment | ✅ | release/readiness/parity docs now share one release story |
| Managed daemon trust as default | 🟡 | still an intentional release decision, not earned by momentum alone |
| Bash fallback boringness | 🟡 | must stay explicit until default-runtime cutover is intentional |

See `docs/v2-release-checklist.md` for the full ship/no-ship checklist.

## Promotion Rubric

### Beta-ready now

Beta is credible because all of these are now true:

- shell regressions pass via `bash tests/run.sh`
- fail-closed runtime scenarios pass via `bash evals/run.sh`
- Elixir service/UI/worktree tests pass via `cd elixir && mix test`
- the real HUD/service path passes via `./forgeloop.sh self-host-proof`
- public screenshots regenerate from canonical loopback state via `./bin/capture-product-screenshots.sh`
- public docs describe the current risk posture honestly

### Beta gate

Do **not** call v2 beta until the checklist in `docs/v2-release-checklist.md` is completed in one reviewed pass.

In practice that means:

- public entrypoint smokes stay green across repo-root and vendored layouts for daemon, service, and workflow paths
- the beta proof cadence stays green enough that release-review evidence is fresh, not one-off theater
- disposable-worktree cleanup and babysitter recovery/watchdog checks are explicit and green
- the OpenClaw/plugin seam has bounded smoke coverage, not just prose confidence
- the release/readiness/parity docs all reflect the same truth about what is landed and what is still deferred
- a human release review explicitly decides “yes, this is beta”

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
- Beta proof workflow:
  - `.github/workflows/v2-beta-proof.yml`

## Review Prompts

- Does the loop stop safely on repeated identical failures?
- Can a new operator find the control rules without reading the source first?
- Can we regenerate the public screenshots and proof artifacts from real loopback state instead of mocked demos?
- Are the release-track docs and the code/test reality saying the same thing?
- If the managed daemon path regressed tomorrow, would the bash fallback story still be obvious and safe?
