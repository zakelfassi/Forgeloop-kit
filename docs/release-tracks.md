# Release Tracks

Forgeloop ships on two tracks. Pick the one that matches how you want to use it.

## Stable track

- **Version:** [`v1.0.0`](https://github.com/zakelfassi/Forgeloop-kit/releases/tag/v1.0.0)
- **Status:** stable
- **Runtime posture:** bash-first public runtime
- **Best for:** teams using coding agents on real projects today

Pin to `v1.0.0` when you want the proven runtime without evaluating new surfaces.

## Main track

- **Branch:** `main`
- **Status:** **v2 beta / development track**
- **Runtime posture:** additive Elixir + bash coexistence work
- **Best for:** teams who want the live dashboard, event streams, OpenClaw plugin, workflow packs, and the richer developer experience without waiting for prod-default cutover

`main` is **not** the stable/default track yet. It is now the beta track.

For the exact ship/no-ship checklist, see `v2-release-checklist.md`.

## What beta means now

The v2 track has earned **beta** because the repo can now say all of this truthfully:

- daemon, service, and workflow public entrypoints are covered across repo-root and vendored layouts
- shell, eval, Elixir, self-host proof, and screenshot regeneration are part of a repeatable release-proof rhythm
- babysitter/worktree cleanup and recovery checks are explicit enough for release review
- plugin seams such as OpenClaw have bounded smoke coverage
- release/readiness/parity docs all describe the same landed reality

Beta is therefore a **proof and trust milestone**, not just a feature-count milestone.

## What prod-default will mean

Making v2 the **default** public runtime is a stricter call than calling it beta.

That cutover should happen only when the stricter checklist in `v2-release-checklist.md` is met, including:

- the beta gate is already met
- the managed daemon path has earned trust as the recommended path
- the bash fallback/rollback path is still explicit and safe
- there is no unresolved safety-critical drift around fail-closed pauses, escalation artifacts, runtime-state semantics, provider failover, or layout portability

Until then, v1 remains the stable/public recommendation and v2 remains the richer evaluation track.

## What stays true on both tracks

These stay the same on both tracks:

- all state lives in plain files in your repo
- `IMPLEMENTATION_PLAN.md` is the default backlog
- the checklist lane is the default execution path
- tasks and workflow lanes are opt-in

## How to choose

Choose **`v1.0.0`** if you want:

- the proven bash runtime for production agent work
- the smallest risk surface
- to skip the v2 evaluation for now

Choose **`main`** if you want:

- the live dashboard and real-time HUD
- the OpenClaw plugin
- workflow packs and managed daemon execution
- replayable event streams
- disposable-worktree isolation
- the end-to-end self-host proof
- a beta track you can evaluate with real evidence before trusting it as the default runtime

## Upgrade path from stable to main

If you are already on `v1.0.0`, start with `docs/v1-to-v2-upgrade.md` for the full guide. Quick version:

1. do it on a branch or disposable clone/worktree first
2. update the vendored kit to a current `main` checkout
3. rerun the proof surfaces before trusting the newer runtime
4. keep the file-first repo contract (`REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, `.forgeloop/runtime-state.json`) as the review anchor while you evaluate new surfaces

Typical flow inside an installed repo:

```bash
./forgeloop.sh upgrade --from /path/to/Forgeloop-kit --force
./forgeloop.sh evals
./forgeloop.sh self-host-proof
bash forgeloop/tests/run.sh
```

If you want to stay on the legacy daemon path while evaluating newer docs/runtime surfaces, keep using:

```bash
FORGELOOP_DAEMON_RUNTIME=bash ./forgeloop.sh daemon 300
```

## Read next

- `docs/v1-to-v2-upgrade.md`
- `../design.md`
- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `docs/elixir-parity-matrix.md`
- `docs/workflows.md`
