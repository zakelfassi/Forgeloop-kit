# Release Tracks

Forgeloop currently ships on two clearly different tracks.

## Stable track

- **Version:** [`v1.0.0`](https://github.com/zakelfassi/Forgeloop-kit/releases/tag/v1.0.0)
- **Status:** stable
- **Runtime posture:** bash-first public runtime
- **Best for:** projects that want the current stable control-plane contract without following ongoing V2 work

If you want the conservative choice for an active project today, pin to `v1.0.0`.

## Main track

- **Branch:** `main`
- **Status:** **v2 alpha / development track**
- **Runtime posture:** additive Elixir + bash coexistence work
- **Best for:** contributors, evaluators, and teams explicitly trying the loopback service, HUD, OpenClaw seam, managed daemon path, and experimental workflow-pack lane

`main` is **not** the stable track yet.

It is also **not** the beta track yet. The repo still treats beta as a future milestone after the current parity and release-hardening work lands.

## What stays true on both tracks

These product truths do not change:

- the file-first control plane stays canonical
- `IMPLEMENTATION_PLAN.md` remains the phase-1 canonical backlog
- the checklist lane remains the default path
- the tasks lane is still opt-in
- the workflow lane is still experimental and opt-in

## How to choose

Choose **`v1.0.0`** if you want:

- the stable bash runtime
- the current public release line
- fewer moving parts while adopting Forgeloop in a project

Choose **`main`** if you want to evaluate or contribute to:

- the Elixir control-plane service and operator HUD
- managed babysitter/worktree execution
- the OpenClaw integration seam
- replayable event streams and coordination advisory surfaces
- the experimental workflow-pack lane and managed daemon workflow request path

## Upgrade path from stable to main

If you are already using `v1.0.0` and want to evaluate the V2 alpha track:

1. do it on a branch or disposable clone/worktree first
2. update the vendored kit to a current `main` checkout
3. rerun the proof surfaces before trusting the newer runtime
4. keep the file-first repo contract (`REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, `.forgeloop/runtime-state.json`) as the review anchor while you evaluate new surfaces

Typical flow inside an installed repo:

```bash
./forgeloop.sh upgrade --from /path/to/Forgeloop-kit --force
./forgeloop.sh evals
bash forgeloop/tests/run.sh
```

If you want to stay on the legacy daemon path while evaluating newer docs/runtime surfaces, keep using:

```bash
FORGELOOP_DAEMON_RUNTIME=bash ./forgeloop.sh daemon 300
```

## Read next

- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `docs/elixir-parity-matrix.md`
- `docs/workflows.md`
