# Upgrading from Stable v1 to the V2 Alpha Track

This guide is for teams already using **Forgeloop v1.0.0** who want to evaluate the current **`main` / v2 alpha** track without confusing that evaluation with a stable upgrade.

The short version:

- `v1.0.0` is still the stable release
- `main` is still alpha
- the right posture is **evaluate deliberately**, not “blindly upgrade prod”

See also:

- `docs/release-tracks.md`
- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `../design.md` for the current landing-page / HUD launch direction on the alpha track

## What changes on the V2 alpha track

Moving from stable v1 to `main` means evaluating more than just runtime internals.

You are opting into a broader product surface that currently includes:

- additive Elixir + bash coexistence work
- the loopback service
- the operator HUD
- explicit ownership/start-gate visibility
- replayable event streams
- the OpenClaw seam
- the manual `./forgeloop.sh self-host-proof` release proof
- the current v2 alpha visual/product system for the landing page and HUD

## What does **not** change

These remain the trust anchors on both tracks:

- the file-first control plane stays canonical
- `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, and `.forgeloop/runtime-state.json` remain the review surface
- the checklist lane remains the default path
- `IMPLEMENTATION_PLAN.md` remains the phase-1 canonical backlog
- fail-closed behavior matters more than feature count

## When to stay on v1 stable

Stay on `v1.0.0` if you want:

- the conservative runtime choice for active project work
- the current stable public release line
- fewer moving parts while adopting Forgeloop
- to avoid evaluating the Elixir service/HUD/OpenClaw/operator surfaces right now

## Recommended evaluation posture

Evaluate V2 alpha like this:

1. use a branch, disposable clone, or disposable worktree
2. keep the old stable path easy to restore
3. rerun both proof surfaces before trusting the newer runtime
4. prefer explicit fallback settings over guessing
5. review canonical repo-local artifacts, not just UI state

## Upgrade flow inside an installed repo

From the target repo that already has Forgeloop installed:

```bash
./forgeloop.sh upgrade --from /path/to/Forgeloop-kit --force
./forgeloop.sh evals
./forgeloop.sh self-host-proof
bash forgeloop/tests/run.sh
```

That sequence gives you:

- updated vendored kit contents from the newer checkout
- the public safe-autonomy proof (`evals`)
- the manual alpha release proof for the real loopback service/HUD path (`self-host-proof`)
- the broader shell regression suite from the vendored kit

## Recommended post-upgrade checks

After upgrading, explicitly check:

### 1. Public proof still passes

```bash
./forgeloop.sh evals
```

### 2. The real operator product path still passes

```bash
./forgeloop.sh self-host-proof
```

### 3. The service/HUD can be launched manually

```bash
./forgeloop.sh serve
```

### 4. Canonical artifacts still look correct

Check these files after normal runs and after any pause/escalation path:

- `REQUESTS.md`
- `QUESTIONS.md`
- `ESCALATIONS.md`
- `.forgeloop/runtime-state.json`

## Daemon posture while evaluating alpha

If you want the newer docs/service/HUD/operator surfaces but want to stay on the legacy public daemon path, force it explicitly:

```bash
FORGELOOP_DAEMON_RUNTIME=bash ./forgeloop.sh daemon 300
```

Use that during evaluation when you want:

- newer surfaces and docs
- explicit legacy daemon behavior
- lower risk while comparing alpha work against stable expectations

## What to pay attention to during evaluation

Treat these as the real acceptance bar:

- does it pause instead of spin?
- does it preserve the escalation artifact chain?
- does the runtime state remain legible?
- are ownership/start-gate failures explicit instead of confusing?
- do repo-root and vendored layouts still behave correctly?
- does the self-host proof reflect the real product path?

## Rollback posture

If the alpha track is not ready for your repo, roll back cleanly:

1. restore the prior vendored kit / stable reference
2. rerun `./forgeloop.sh evals`
3. keep the stable daemon/runtime path as the default again
4. treat any alpha findings as evaluation notes, not half-adopted state

## Suggested evaluation checklist

- [ ] Upgrade on a disposable branch/clone/worktree
- [ ] Run `./forgeloop.sh evals`
- [ ] Run `./forgeloop.sh self-host-proof`
- [ ] Launch `./forgeloop.sh serve`
- [ ] Review canonical repo-local artifacts after a normal run
- [ ] Review canonical repo-local artifacts after a pause/escalation path
- [ ] Decide whether daemon evaluation should stay on `FORGELOOP_DAEMON_RUNTIME=bash`
- [ ] Record findings before adopting the alpha track more broadly

## Read next

- `docs/release-tracks.md`
- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `docs/elixir-parity-matrix.md`
- `../design.md`
