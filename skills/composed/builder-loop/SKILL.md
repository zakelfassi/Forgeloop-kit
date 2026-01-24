---
name: builder-loop
description: "End-to-end closed-loop build flow (brief -> plan -> forge skills -> execute -> validate). Use when you want a repeatable build loop that improves itself by forging reusable skills over time."
---

# Builder Loop

## Composition

1. `project-architect` -> write/update the plan (tasks + acceptance + runbook).
2. `skillforge` -> create the minimal project skills needed to execute repeatedly (under `skills/<type>/<name>/`).
3. Sync skills for the active agent (`./ralph/bin/sync-skills.sh`).
4. `completion-director` -> execute one unit of work, validate, repeat.

## Output

- Updated plan artifacts (`IMPLEMENTATION_PLAN.md` / `prd.json`)
- Forged project skills under `skills/*/*/` (kit ships its own base skills under `ralph/skills/`)
- A working codebase that passes checks
