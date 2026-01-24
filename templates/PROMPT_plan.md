# Ralph Planning Prompt

## Context Loading

0a. Study `specs/*` to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md (if present) to understand the plan so far.
0c. Study `docs/*` for product requirements, design specs, and architecture decisions.
0d. For reference, study the source code in `src/*`, `apps/*`, `packages/*`, and other relevant folders.

## Your Mission

1. **Planning only** - compare the current codebase against `specs/*` and produce/update @IMPLEMENTATION_PLAN.md as a prioritized checklist (bullet list), focusing on missing/incorrect behavior.

2. **For each checklist item, include REQUIRED TESTS** derived from acceptance criteria in specs:
   - What outcomes must be verified: behavior, edge cases, performance, security
   - Specify WHAT to verify, not HOW to implement

3. **Skill opportunities (optional but preferred):** If you notice repeated workflows across tasks, propose a small Skill to capture them (to be created under `skills/<type>/<name>/SKILL.md` at repo root).

## REQUIRED TESTS Examples

Good (what to verify):
```
- [ ] Add user authentication
  - REQUIRED TESTS:
    - Login with valid credentials returns session token
    - Login with invalid credentials returns 401 error
    - Session expires after 24 hours of inactivity
    - Protected routes redirect unauthenticated users
```

Bad (how to implement):
```
- [ ] Add user authentication
  - Use bcrypt for password hashing
  - Store sessions in Redis
```

## Rules

**IMPORTANT:**
- Plan only. Do NOT implement anything.
- Do NOT assume functionality is missing; confirm with code search first.
- Keep @IMPLEMENTATION_PLAN.md current and avoid duplicating work.
- Prioritize by impact and dependencies (foundational tasks first).

## When Blocked

If specs are ambiguous or you need clarification:
```bash
./ralph/bin/ask.sh "clarification" "What does X mean in spec Y?"
```

Then STOP and wait for the answer. Do not guess requirements.
