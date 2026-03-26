# V2 Release Checklist

_As of March 25, 2026_

This page is the practical ship/no-ship checklist for the `main` / v2 track.

It exists so the repo can answer one question clearly:

> Are we ready to call v2 beta, or make v2 the default public runtime?

Short answer today:

- **v2 is a serious alpha**
- **v2 is not beta yet**
- **v2 is not the prod-default/runtime recommendation yet**

Use this page for release review instead of reconstructing the bar from multiple docs.

## Current release call

### What we can say truthfully now

- the shell gate is codified and greenable with `bash tests/run.sh`
- fail-closed runtime scenarios are codified and greenable with `bash evals/run.sh`
- the Elixir control plane, service, HUD, babysitter, and workflow stack are codified and greenable with `cd elixir && mix test`
- the real HUD/service path has a one-command proof via `./forgeloop.sh self-host-proof`
- public HUD screenshots regenerate from a seeded canonical demo repo via `./bin/capture-product-screenshots.sh`
- daemon, service, workflow, and OpenClaw plugin seams now have explicit public/integration smoke coverage

### What we should **not** say yet

- that v2 is beta
- that v2 is the default public runtime
- that the managed daemon path has fully replaced the bash fallback story

## Release scoreboard

| Area | Current status | Evidence |
| --- | --- | --- |
| Shell regression gate | ✅ Greenable now | `bash tests/run.sh` |
| Fail-closed scenario harness | ✅ Greenable now | `bash evals/run.sh` |
| Elixir suite | ✅ Greenable now | `cd elixir && mix test` |
| Real HUD/service proof | ✅ Present | `./forgeloop.sh self-host-proof` |
| Public screenshot regeneration | ✅ Present | `./bin/capture-product-screenshots.sh` |
| Public entrypoint smokes | ✅ Present | `tests/daemon-entrypoint-layouts.test.sh`, `tests/service-entrypoint-layouts.test.sh`, `tests/workflow-entrypoint-layouts.test.sh` |
| OpenClaw contract seam | ✅ Present | `tests/openclaw-plugin.test.sh` |
| OpenClaw real loopback integration smoke | ✅ Present | `tests/openclaw-loopback-smoke.test.sh` |
| Babysitter cleanup / recovery proof | ✅ Present | `elixir/test/forgeloop_v2/babysitter_test.exs`, `elixir/test/forgeloop_v2/daemon_test.exs` |
| Release docs aligned to shipped reality | ✅ Good enough for alpha | `README.md`, `docs/harness-readiness.md`, `docs/release-tracks.md`, `docs/v2-roadmap.md`, `docs/elixir-parity-matrix.md`, `QUALITY_SCORE.md` |
| Managed daemon trust as the recommended path | 🟡 Not fully earned yet | Needs intentional beta/prod-default review, not just green tests |
| Bash fallback / rollback boringness | 🟡 Still part of the release bar | Keep `FORGELOOP_DAEMON_RUNTIME=bash` explicit until cutover is intentional |

## Beta checklist

Do **not** call v2 beta until all of the following are true in one reviewed pass:

- [ ] `bash tests/run.sh`
- [ ] `bash evals/run.sh`
- [ ] `cd elixir && mix test`
- [ ] `./forgeloop.sh self-host-proof`
- [ ] `./bin/capture-product-screenshots.sh`
- [ ] public entrypoint smokes stay green across repo-root and vendored layouts
- [ ] OpenClaw contract and loopback integration smokes stay green
- [ ] babysitter cleanup/recovery proofs stay green
- [ ] release docs still match what the code/tests actually prove
- [ ] a human release review explicitly decides “yes, this is beta” instead of letting momentum imply it

## Prod-default checklist

Do **not** make v2 the default public runtime until all of the following are true:

- [ ] the beta checklist is already met
- [ ] there is no unresolved safety-critical drift around fail-closed pauses, escalation artifacts, runtime-state semantics, provider failover, or layout portability
- [ ] the managed daemon path has earned trust as the recommended path, not just the richer path
- [ ] the bash fallback story is still explicit, safe, and easy to roll back to
- [ ] docs and upgrade guidance reflect the cutover intentionally
- [ ] the release decision is explicit in repo docs, not inferred from feature momentum

## Release review runbook

Run these in order during a release review:

```bash
bash tests/run.sh
bash evals/run.sh
cd elixir && mix test
cd ..
./forgeloop.sh self-host-proof
./bin/capture-product-screenshots.sh
```

Then verify:

1. screenshots still represent the shipped HUD truthfully
2. self-host proof artifacts are reviewable
3. `docs/release-tracks.md` still matches the intended recommendation
4. `QUALITY_SCORE.md` still matches the actual confidence level
5. rollback/fallback instructions are still boring and obvious

## Why this is still alpha today

The repo now has a real proof path, but the release recommendation is still conservative on purpose.

The remaining step is **not** inventing more architecture. It is making an intentional release decision about trust:

- whether the managed daemon path has earned “recommended” status
- whether the fallback/rollback story is still comfortable enough for public default use
- whether we want one more sustained release-review cycle before calling beta

That is why the current call remains:

- **serious alpha now**
- **beta after one explicit reviewed pass of this checklist**
- **prod-default after a stricter trust/cutover decision**
