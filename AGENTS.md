# Forgeloop-kit AGENTS

This file is the repo-root table of contents for agents working on **Forgeloop-kit itself**.
Keep it short. Keep durable rules in `docs/`. Prefer repo-local, versioned artifacts over chat context or memory.

## What this repo is

Forgeloop-kit is the repo-local safe-autonomy control plane for coding agents.
Its core product is a fail-closed loop: agents plan/build against real checks, pause instead of spin, and preserve state in repo files when human judgment is required.

The three execution lanes are:
- checklist lane — `IMPLEMENTATION_PLAN.md` with `plan` / `build`
- tasks lane — `prd.json` with `tasks`
- workflow lane — native workflow packs with `workflow ...`

## Read first

Read in this order before changing behavior:
1. `README.md`
2. `docs/README.md`
3. `docs/runtime-control.md`
4. `docs/workflows.md` when touching workflow behavior
5. `docs/harness-readiness.md`
6. `docs/sandboxing.md` when changing permissions, runners, or full-auto behavior

## How to navigate this repo

- `bin/` — bash entrypoints and loop/daemon control surfaces
- `lib/` — shared bash runtime helpers
- `elixir/` — managed daemon, babysitter, loopback service, and UI foundation
- `templates/` — files installed into target repos; do not confuse these with this repo's own root docs
- `docs/` — authoritative long-form operator and architecture contracts
- `design.md` — current visual brief for the landing page and operator HUD on the v2 alpha track
- `tests/` — shell regression suite
- `evals/` — public safe-autonomy proof harness
- `.openclaw/` — OpenClaw integration seam
- `config.sh` — canonical environment/config knobs

## Working rules

- Treat `AGENTS.md` as a map, not an encyclopedia.
- Confirm current behavior from code and tests before editing docs or prompts.
- Keep changes small, legible, and mechanically verifiable.
- If you change durable behavior, update the matching doc in `docs/`.
- If you change installed-repo scaffolding, update `templates/` and any affected install tests.
- Do not duplicate the runtime-control or workflow contracts here; link to them.
- Preserve the file-first control plane: `REQUESTS.md`, `QUESTIONS.md`, `ESCALATIONS.md`, and `.forgeloop/runtime-state.json` are part of the product surface.
- Prefer repo-local knowledge over hidden context: if an agent needs it repeatedly, encode it in the repository.
- Reduce entropy when you touch a surface: collapse stale docs, dead prompts, and drift rather than adding more parallel guidance.
- If you change the landing page or operator HUD direction, update `design.md` in the same slice.

## Validation

Run the smallest relevant suite, then widen when your change crosses boundaries:

- bash/runtime/install/template changes: `bash tests/run.sh`
- fail-closed runtime behavior, escalation paths, daemon transitions, proof-harness changes: `bash evals/run.sh`
- Elixir service/UI/babysitter/OpenClaw-managed changes: `cd elixir && mix test`

For broad runtime or cross-surface changes, run all relevant suites.

## Safety boundaries

- Forgeloop should **fail closed, not spin**. Follow `docs/runtime-control.md`.
- Keep `FORGELOOP_VERIFY_CMD` validation-only; deploy/restart actions belong in deploy hooks.
- Treat the VM/container as the real security boundary. Disposable worktrees are hygiene, not security.
- Do not fake recovery state: the next loop/daemon cycle owns recovery.

## Practical prompts for agents

When working here:
- start from the smallest authoritative file that answers the question
- prefer existing entrypoints (`bin/*`, `tests/*`, `evals/*`) over ad hoc scripts
- preserve repo-root and vendored-layout compatibility where applicable
- add or update regression coverage with behavioral changes
- keep repo instructions concise so they remain useful in-context
