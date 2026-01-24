---
name: completion-director
description: "Drive execution as a closed loop: pick the next task, ensure needed skills exist, run checks, iterate until acceptance is met. Use when asked to run/operate a build loop or manage multi-step delivery."
---

# Completion Director

## Locks / Gates

Operate with explicit gates:
1. Plan lock: tasks + acceptance are clear.
2. Forge lock: missing reusable skills are created (only if they pay off).
3. Validation lock: tests/typecheck/lint/security gates pass.

Do not advance past a gate without meeting it.

## Loop

1. Choose the next unit of work
   - The top unchecked Ralph task / the next `passes:false` task.

2. Preflight (skill opportunity)
   - Ask: "Is there a reusable procedure I'm about to repeat?"
   - If yes, use `skillforge` to create/update a focused skill.
   - Sync skills (`./ralph/bin/sync-skills.sh`) so the agent can use them.

3. Execute conservatively
   - Prefer tiny diffs.
   - Keep coordination docs current.

4. Validate
   - Run the repo’s required checks (tests/typecheck/lint).
   - If a check fails, fix it before moving on.

5. Iterate
   - Repeat until acceptance criteria are met and the plan is complete.

## When Blocked

- Stop and ask for clarification (do not guess).
- Record the blocker and what you tried.
