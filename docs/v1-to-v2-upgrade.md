# Upgrading from Stable v1 to the V2 Beta Track

This guide is for teams already on **Forgeloop v1.0.0** who want to try **v2 beta** without risking their current setup.

The short version: evaluate v2 on a branch or disposable clone. Keep v1 easy to restore. Run both proof suites before you commit. Treat today’s v2 as **beta**, not a default-runtime replacement.

See also:

- `docs/release-tracks.md`
- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `../design.md` for the current landing-page / HUD launch direction on the beta track

## What changes on the V2 beta track

v2 beta is not just a runtime swap — it adds a broader developer experience:

- **Live dashboard** with real-time state, blockers, and interactive controls
- **Event streams** you can replay and inspect
- **OpenClaw plugin** for monitoring and steering runs
- **Disposable-worktree isolation** for safer self-hosting
- **Self-host proof** that verifies the full stack end-to-end

## What does **not** change

These stay the same on both tracks:

- all state lives in plain files in your repo
- `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, and `.forgeloop/runtime-state.json` are still the source of truth
- the checklist lane is still the default
- `IMPLEMENTATION_PLAN.md` is still the canonical backlog
- fail-closed behavior still matters more than feature count

## When to stay on v1 stable

Stay on `v1.0.0` if you want:

- the proven runtime for production work
- fewer moving parts
- to skip the dashboard/HUD/plugin evaluation for now

## Recommended evaluation posture

Evaluate v2 alongside v1, not as a replacement:

1. use a branch, disposable clone, or worktree
2. keep the old stable path easy to restore
3. run both proof suites before trusting the newer runtime
4. use explicit fallback settings (`FORGELOOP_DAEMON_RUNTIME=bash`) when in doubt
5. review the plain-file artifacts, not just what the dashboard shows

## Upgrade flow inside an installed repo

From the target repo that already has Forgeloop installed, update the vendored kit and immediately rerun both proof surfaces:

```bash
./forgeloop.sh upgrade --from /path/to/Forgeloop-kit --force
./forgeloop.sh evals
./forgeloop.sh self-host-proof
bash forgeloop/tests/run.sh
```

That sequence gives you a fast confidence check:

- updated vendored kit contents from the newer checkout
- the public safe-autonomy proof (`evals`)
- the manual beta release proof for the real loopback service/HUD path (`self-host-proof`)
- the broader shell regression suite from the vendored kit

## Recommended post-upgrade checks

After upgrading, explicitly check the surfaces you plan to trust:

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

## Daemon posture while evaluating beta

If you want the newer docs/service/HUD/operator surfaces but want to stay on the legacy public daemon path, force it explicitly:

```bash
FORGELOOP_DAEMON_RUNTIME=bash ./forgeloop.sh daemon 300
```

Use that during evaluation when you want:

- newer surfaces and docs
- explicit legacy daemon behavior
- lower risk while comparing beta work against stable expectations

## What to pay attention to during evaluation

These are the real acceptance criteria — not whether the demo boots:

- does it stop retrying when failure repeats?
- are escalation artifacts written correctly?
- is the runtime state consistent and readable?
- are ownership conflicts surfaced clearly?
- does it work in both repo-root and vendored layouts?
- does the self-host proof pass?
- would you still feel safe falling back to `FORGELOOP_DAEMON_RUNTIME=bash` if the managed path surprised you?

## Rollback posture

If v2 doesn't earn your trust yet, roll back:

1. restore the v1 vendored kit
2. rerun `./forgeloop.sh evals`
3. keep the stable daemon path as default
4. treat your findings as evaluation notes, not half-adopted state

## Suggested evaluation checklist

- [ ] Upgrade on a disposable branch/clone/worktree
- [ ] Run `./forgeloop.sh evals`
- [ ] Run `./forgeloop.sh self-host-proof`
- [ ] Launch `./forgeloop.sh serve`
- [ ] Review canonical repo-local artifacts after a normal run
- [ ] Review canonical repo-local artifacts after a pause/escalation path
- [ ] Decide whether daemon evaluation should stay on `FORGELOOP_DAEMON_RUNTIME=bash`
- [ ] Record findings before adopting the beta track more broadly

## Read next

- `docs/release-tracks.md`
- `docs/runtime-control.md`
- `docs/v2-roadmap.md`
- `docs/elixir-parity-matrix.md`
- `../design.md`
