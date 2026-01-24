# Ralph Build Prompt

## Context Loading

0a. Study `specs/*` to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md for the current task list.
0c. Study `docs/*` for product requirements, design specs, and architecture decisions.
0d. For reference, study the source code in `src/*`, `apps/*`, `packages/*`, and other relevant folders.
0e. CHECK @QUESTIONS.md for answered questions (Status: ✅ Answered). If you previously asked a question and it's been answered, read it and proceed accordingly. Mark it as ✅ Resolved after acting on it.
0f. **Skill Forge preflight (always):** Before starting the task, decide if this work would benefit from a reusable Skill (a short procedural guide or tool wrapper you’ll reuse). If yes, create/update a focused Skill under `skills/<type>/<name>/SKILL.md` (repo-root) and then run `./ralph/bin/sync-skills.sh` to refresh agent discovery. (Avoid editing `ralph/skills` unless you’re changing the kit itself.)

## Your Mission

1. **Implement exactly ONE task** - the top prioritized unchecked item in @IMPLEMENTATION_PLAN.md
   - Do NOT combine investigation with implementation
   - Before making changes, search the codebase (do not assume missing) and confirm current behavior
   - Include any REQUIRED TESTS listed in the task

2. **Tests are mandatory:**
   - Add/extend tests for your change
   - Required tests derived from acceptance criteria must exist and pass before committing
   - Run the repo's test command(s) and ensure they pass before committing
   - If this repo has a validate/typecheck/lint script, run it too

3. **Keep coordination docs current:**
   - Update @IMPLEMENTATION_PLAN.md as you learn things
   - After a successful change, update @STATUS.md and append to @CHANGELOG.md under [Unreleased]

## Single Unit of Work Rule

- Implement ONLY the top unchecked item
- Do NOT start the next item after completing one
- Each iteration = one task
- If you finish early, the loop will pick up the next item

## Quality Checks (Run Before Committing)

Run ALL applicable checks:
```bash
# Typecheck
pnpm tsc --noEmit  # or npm run typecheck

# Tests
pnpm test  # or npm test

# Lint
pnpm lint  # or npm run lint
```

Adjust commands based on what's in `AGENTS.md` for this project.

## When Blocked

**DO NOT GUESS** when you encounter:
- **blocked**: Can't proceed without human input
- **clarification**: Specs are ambiguous or contradictory
- **decision**: Multiple valid approaches exist
- **review**: Want feedback before implementing

Use `./ralph/bin/ask.sh`:
```bash
./ralph/bin/ask.sh "blocked" "Detailed question here"
./ralph/bin/ask.sh "clarification" "What does X mean in spec Y?"
./ralph/bin/ask.sh "decision" "Should we use approach A or B?"
```

Then STOP and wait for the answer. Do not continue guessing.

## Browser Verification (If Applicable)

If acceptance criteria mention "verify in browser" or you're implementing UI:
- Use agent-browser or similar tool if available
- Document what you verified
- If browser verification not available, note it as skipped

## Operational Notes

- Progress updates go in `IMPLEMENTATION_PLAN.md`, `STATUS.md`, and `CHANGELOG.md`
- Keep `AGENTS.md` brief and operational (patterns only, not status)
- Implement functionality completely - placeholders and stubs waste effort

## Design Quality (Optional)

If you implement UI, follow the repo's design system and prioritize a premium, intentional UX.
