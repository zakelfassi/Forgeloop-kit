# Ralph Tasks Build Prompt

You are implementing a single task from a structured task list.

## Context Files

Read these files to understand the current state:
1. `prd.json` - Task definitions and completion status
2. `progress.txt` - Codebase patterns and progress log
3. `AGENTS.md` - Project-specific guidance (if exists)

## Your Mission

1. **Read `prd.json`** and find the highest priority task where `passes: false`
2. **Read `progress.txt`** for codebase patterns and learnings
2b. **Skill Forge preflight (always):** Before implementing, decide if this task introduces a repeatable workflow worth capturing as a Skill. If yes, create/update a focused Skill under `skills/<type>/<name>/SKILL.md` (repo-root) and run `./ralph/bin/sync-skills.sh`. (Avoid editing `ralph/skills` unless you’re changing the kit itself.)
3. **Implement ONLY that one task** - no more, no less
4. **Verify acceptance criteria** by running the specified checks
5. **Update files** when done:
   - Set `passes: true` in `prd.json` for the completed task
   - Add notes to the task's `notes` field if useful
   - Append progress entry to `progress.txt`

## Rules

### Single Unit of Work
- Implement exactly ONE task per iteration
- Do NOT combine investigation with implementation
- Do NOT start the next task after completing one
- If blocked, stop and document the blocker

### Quality Checks
Run the project's quality checks before marking complete:
- Typecheck (if applicable): `pnpm tsc --noEmit` or similar
- Tests (if applicable): `pnpm test` or similar
- Lint (if applicable): `pnpm lint` or similar

### When Blocked
If you cannot complete the task:
1. Do NOT mark `passes: true`
2. Add details to the task's `notes` field
3. Document the blocker in `progress.txt`
4. Use `./ralph/bin/ask.sh blocked "description"` if human input needed

### Browser Verification
If acceptance criteria mention "verify in browser":
- Use agent-browser or similar tool if available
- Document what you verified in `progress.txt`
- If browser verification not available, note it as skipped

## Progress Entry Format

When you complete or make progress on a task, append to `progress.txt`:

```
### T-XXX - Task Title
**Completed:** [timestamp]
**Status:** completed

**What changed:**
- List of files modified
- Key implementation details

**Learnings:**
- Patterns discovered
- Gotchas to remember

---
```

## Completion Signal

When ALL tasks in `prd.json` have `passes: true`, output exactly:
```
<promise>COMPLETE</promise>
```

This signals the loop to stop.
