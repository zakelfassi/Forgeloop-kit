---
name: git-heavy-atoms-pr
description: Create reviewable, heavy-atom git commits from current changes (working tree by default; optionally staged/unstaged/range), then push a branch and open a PR. Use when you need to split mixed changes into a small number of cohesive commits (not tiny commits) and ship via GitHub PR.
---

# Git Heavy Atoms PR

## Goal

Turn “whatever is currently changed” into a clean PR:

- Read current git changes (default: working tree)
- Split into **heavy atoms** (few, cohesive commits)
- Make commits with clean staging (often via patch staging)
- Push a branch and open a PR

## Definitions (heavy atoms)

**Heavy atom** = the smallest commit that:

- Is **cohesive** (one intent) and easy to review
- Is **buildable/testable** (or as close as the repo allows)
- Avoids “tiny commits” (renames-only, single-line commits) unless it materially reduces risk
- Separates concerns only when it helps review, safety, or deploy ordering

Good heavy atoms:

- “Add endpoint + tests + serializer”
- “Refactor service object + keep behavior identical (tests green)”
- “Add migration (backwards compatible) + app support” (or split if deploy ordering matters)

Bad atoms:

- “Fix typo”
- “More changes”
- “WIP”
- “Formatting sweep mixed with logic changes”

## Pre-flight questions (ask/confirm)

1. **Diff scope** (pick one):
   - Working tree (staged + unstaged): `git diff` + `git diff --staged`
   - Staged only: `git diff --staged`
   - Unstaged only: `git diff`
   - Range: `git diff BASE..HEAD` (or `BASE...HEAD`)
2. **Base branch**: usually `main` (verify) and remote `origin`
3. **Target**: draft PR vs ready-for-review PR
4. **Commit style**: Conventional Commits vs repo-native style
5. **Repo rules**: read applicable `AGENTS.md` / contribution rules before running tests or generators

## Workflow

### 1) Inspect and summarize the change set

Run:

- `git status -sb`
- `git diff --stat`
- `git diff --name-status`
- `git diff --staged --stat` (if anything staged)

Build a short inventory:

- Files changed per “theme” (feature/fix/refactor/tests/docs/tooling)
- Risky areas (auth, payments, migrations, infra, prod configs, permissions)
- Any mixed hunks in the same file that belong to different atoms

### 2) Propose atoms (few commits, not many)

Target: **2–6 commits per PR** (typical).

Heuristics:

- Separate **behavior changes** from **mechanical refactors** when it reduces review risk.
- Keep **tests with the code** they validate (same commit) unless tests are a large standalone harness update.
- Keep **formatting** separate if it touches many lines unrelated to the change intent.
- For **migrations / deploy-ordered changes**, split only when order matters:
  1. backwards-compatible migration
  2. app code that works with both schemas
  3. cleanup migration / removal (optional)

For each proposed atom, write:

- Title (candidate commit subject)
- Files/hunks included
- Safety note (deploy ordering, flags, rollback)
- Testing note (what to run)

### 3) Create/confirm branch

If not already on a feature branch, create one.

- Prefer branch prefix `codex/` (e.g., `codex/auth-refresh-token`).

### 4) Stage and commit atom-by-atom

For each atom:

1. Ensure index is clean for the atom:
   - If needed: `git reset` (unstage everything), then stage selectively
2. Stage only what belongs:
   - `git add -p <paths...>` (preferred)
   - `git reset -p <paths...>` (to unstage mistaken hunks)
3. Sanity check staged diff:
   - `git diff --staged`
4. Run the smallest meaningful verification for that atom (repo rules apply):
   - Unit tests for touched modules, lint/format if required, etc.
5. Commit with a clear message:
   - Subject: imperative, specific, ≤72 chars
   - Body: why + notable tradeoffs + “Testing:” line if repo doesn’t auto-template

Guardrails:

- Do not use `git add .` unless changes are already cleanly separated.
- Do not commit secrets; scan diffs for keys/tokens before committing.
- If you need to move code across atoms, prefer `git commit --amend` (same atom) or `git rebase -i` (afterwards).

### 5) Final verification

Before PR:

- `git status -sb` (clean working tree preferred)
- `git log --oneline --decorate -n 20` (review commit sequence)
- Run the repo’s “PR gate” command(s) if they exist and are reasonable in scope.

### 6) Push and open PR

Push:

- `git push -u origin HEAD`

Create PR (GitHub CLI preferred):

- `gh pr create --fill`

If you must supply content, include:

- What changed (1–3 bullets)
- Why
- Testing performed
- Risk/rollout notes (migrations, flags, env vars)

## Patterns for common messy states

### A) Mixed staged/unstaged changes

- Decide whether to treat staged as one atom.
- If staged is mixed: `git reset` then rebuild staging by atoms with `git add -p`.

### B) One file contains multiple intents

- Use patch staging (`git add -p`) to slice hunks into the right atoms.
- If hunks are interleaved, consider a small refactor to separate code paths first.

### C) Generated files / lockfiles

- Keep lockfile changes in the atom that necessitated them.
- If generator output is huge, consider one atom: “Regenerate X” (only if it’s the primary intent).

## Output expectations

When executing this skill, produce:

- The proposed atom list (2–6 items) with per-atom testing notes
- The exact git commands you ran (or plan to run) for staging/committing
- A PR summary (title + body) ready for `gh pr create`
