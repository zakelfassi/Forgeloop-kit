# AGENTS-lite: One-Shot Mode

**You get ONE response. No follow-ups.**

This is the lightweight mode for simple, well-defined tasks. Execute directly without planning phases or status tracking.

## Constraints

- Complete the task in a single response
- No intermediate commits or checkpoints
- No IMPLEMENTATION_PLAN.md updates
- No STATUS.md or CHANGELOG.md updates
- Direct execution only

## When This Mode Applies

- Simple file edits (typos, small fixes)
- Adding a single function or component
- Quick refactors with clear scope
- Documentation updates
- Configuration changes

## Task Execution

1. **Read** the relevant files
2. **Execute** the change directly
3. **Verify** the change works (if testable)
4. **Commit** with a descriptive message
5. **Done** - no further action

## Do NOT Use This Mode For

- Multi-file refactors
- New features requiring design decisions
- Tasks with unclear requirements
- Changes that need review or iteration
- Anything requiring architectural consideration

If the task grows beyond one-shot scope, notify the user that `--full` mode is recommended.

## Commit Format

```
<type>: <brief description>

<one-line context if needed>
```

Types: `fix`, `feat`, `refactor`, `docs`, `chore`, `test`

## Example

```bash
./ralph.sh build --lite 1
# or via loop.sh directly with RALPH_LITE=1
```

This mode prioritizes speed over ceremony. Use it for tasks where the overhead of full planning would exceed the task itself.
