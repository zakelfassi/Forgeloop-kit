# PaneForge Forgeloop Upgrade Handoff

Date: 2026-03-06

## Context

This note captures the VM investigation into `/home/zakelfassi/PaneForge` on:

`ssh -p 1990 zakelfassi@95.217.196.220`

Purpose: determine whether PaneForge could be upgraded with the same Forgeloop control-plane bundle used for other repos on the VM.

Conclusion: do not run a blind `upgrade --from` on PaneForge. Its vendored `forgeloop/` is not a clean upstream snapshot; it is a live local fork with custom commits plus additional uncommitted edits.

## What Was Upgraded Successfully Elsewhere

These repos were upgraded successfully from the current `Forgeloop-kit` bundle:

- `bourse-de-casa`
- `TheEdit`
- `memory-app`
- `gablus`

This repo was already current:

- `tac-monorepo`

PaneForge was the only repo intentionally skipped.

## PaneForge Findings

Repo path on VM:

`/home/zakelfassi/PaneForge`

Top-level `git status` showed normal project edits plus Forgeloop-specific changes:

- `CHANGELOG.md`
- `IMPLEMENTATION_PLAN.md`
- `STATUS.md`
- `forgeloop/bin/forgeloop-daemon.sh`
- `forgeloop/bin/session-start.sh`
- `forgeloop/config.sh`
- `forgeloop/lib/core.sh`
- `forgeloop/lib/llm.sh`

There are also many untracked skill-related files at the repo root:

- `.claude/skills/forgeloop-*`
- `.claude/skills/persona-distiller`
- `.claude/skills/saf-classifier`
- `.claude/skills/semantic-profile-builder`
- `.claude/skills/spec-audit`
- `.claude/skills/vault-generator`
- `.codex/`
- `skills/operational/spec-audit/`

## Nested Forgeloop State

The nested `forgeloop/` is behaving like a real local fork, not a passive vendored copy.

Nested status:

- branch: `main...origin/main`
- dirty files:
  - `bin/forgeloop-daemon.sh`
  - `bin/session-start.sh`
  - `config.sh`
  - `lib/core.sh`
  - `lib/llm.sh`

Nested commit head:

- `9e38c08 forgeloop: pause daemon`

Recent nested commits:

- `9e38c08 forgeloop: pause daemon`
- `ae7f031 feat(forgeloop): add flag.sh library for goal-directed loops`
- `6446cfe feat(forgeloop): add auth error detection and failover`
- `ce29521 unpause: resume forgeloop on anvil`
- `927ba27 fix: sync forgeloop-kit — strict schemas + auth/schema error detection`

Important detail: inside the nested `forgeloop/`, `origin` points to the PaneForge repo itself, not to `Forgeloop-kit`.

## Why Blind Upgrade Is Risky

The local Forgeloop edits in PaneForge are substantial, not incidental.

Observed diff shape:

- `forgeloop/bin/forgeloop-daemon.sh`: very large local expansion
- `forgeloop/lib/llm.sh`: large local auth/state/security hardening
- `forgeloop/lib/core.sh`: runtime directory and permission changes
- `forgeloop/config.sh`: local config additions
- `forgeloop/bin/session-start.sh`: smaller local changes

Examples seen during inspection:

- sentinel exit codes for auth failure / no-LLM
- integer sanitization helpers for daemon env vars
- strict state-file permission validation before restoring auth state
- `PENDING_AUTH_VERIFICATION` and insecure-state lock behavior
- more aggressive daemon-side auth failure latching
- runtime directory permission normalization in `lib/core.sh`

These signatures are not present in current upstream `Forgeloop-kit` `main` as of local head `53ec016`.

That means a normal upgrade would not just refresh the kit. It would overwrite unpublished PaneForge-specific Forgeloop work.

## Recommended Unblock Path

Do this in order:

1. Snapshot the current PaneForge Forgeloop fork before any upgrade.
2. Separate custom behavior worth preserving from generic vendored drift.
3. Re-upgrade from current `Forgeloop-kit`.
4. Port the preserved behavior back on top in focused commits.

More concretely:

1. Create a dedicated safety branch in `PaneForge` that captures the current dirty state.
2. Export a patch or commit series for:
   - `forgeloop/lib/llm.sh`
   - `forgeloop/bin/forgeloop-daemon.sh`
   - `forgeloop/lib/core.sh`
   - `forgeloop/config.sh`
   - `forgeloop/bin/session-start.sh`
3. Compare each local behavior against current upstream and classify it:
   - keep and upstream later
   - keep but PaneForge-specific
   - discard as obsolete
4. Only after that, run the standard Forgeloop upgrade into PaneForge.
5. Re-apply the kept logic in small reviewed commits.

## What I Would Preserve First

Highest-signal candidates to preserve or re-port:

- auth failure detection and failover behavior in `forgeloop/lib/llm.sh`
- daemon-side auth/backpressure logic in `forgeloop/bin/forgeloop-daemon.sh`
- secure runtime/state permission handling in `forgeloop/lib/core.sh`

Lower-priority candidates:

- `forgeloop/bin/session-start.sh`
- `forgeloop/config.sh`

## What The Next Agent Should Check First

1. Does PaneForge actually still need all the local auth/security hardening, or has some of it been superseded by current upstream?
2. Are the nested Forgeloop commits intended to stay project-local, or should they be upstreamed into `Forgeloop-kit`?
3. Can the nested repo model be retired after reconciliation, so future upgrades do not depend on a self-pointing `origin`?

## Suggested First Commands

On the VM:

```bash
ssh -p 1990 zakelfassi@95.217.196.220
cd /home/zakelfassi/PaneForge
git status --short --branch
git diff --stat -- forgeloop
git -C forgeloop log --oneline -10
git -C forgeloop diff -- lib/llm.sh bin/forgeloop-daemon.sh lib/core.sh
```

In local `Forgeloop-kit`:

```bash
cd /Users/zakelfassi/Library/CloudStorage/Dropbox/Experiments/Forgeloop-kit
git rev-parse --short HEAD
rg -n "FORGELOOP_EXIT_AUTH_FAILURE|PENDING_AUTH_VERIFICATION|sanitize_int|normalize_perms" lib bin tests docs
```

## Bottom Line

PaneForge is blocked on reconciliation, not on a missing upgrade command.

The right move is:

- preserve the local Forgeloop fork first
- then upgrade deliberately
- then port only the pieces that still matter

Do not overwrite `PaneForge/forgeloop` in place without capturing its current delta.
