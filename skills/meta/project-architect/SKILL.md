---
name: project-architect
description: "Turn a freeform brief into a concrete build plan: requirements, tasks, skill opportunities, runbook, risks, acceptance. Use when asked to plan a feature/project, refine IMPLEMENTATION_PLAN.md, or create a skills blueprint before building."
---

# Project Architect

## Output Contract

Produce a plan that is immediately executable, with:
- Requirements (functional + non-functional)
- Task breakdown (small, dependency-aware)
- Skill opportunities (what to automate/templatize)
- Runbook (commands + expected artifacts)
- Risks / unknowns / decision points
- Acceptance tests (verifiable)

## Steps

1. Extract requirements
   - What must exist when done?
   - What must NOT change?
   - Edge cases and failure modes.

2. Decompose into tasks
   - Right-size: one agent iteration per task.
   - Separate investigation from implementation.
   - Include required tests/checks per task (what to verify).

3. Identify skill opportunities
   - Look for repeated patterns that will recur across tasks.
   - Propose *minimal* new skills (avoid over-forging).
   - For each candidate skill, provide:
     - name, type (`operational|meta|composed`)
     - 1-2 sentence description (with triggers)
     - inputs/outputs
     - example prompts

4. Write runbook + acceptance
   - Commands to run locally (build/test/lint/typecheck).
   - Acceptance checks that are machine-verifiable when possible.

## Notes

- If this project uses Ralph Kit: keep the plan aligned with `IMPLEMENTATION_PLAN.md` and Ralph's “single unit of work” iteration model.
