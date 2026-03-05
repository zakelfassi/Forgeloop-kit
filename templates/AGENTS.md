# Project Operational Guide

This file contains project-specific guidance for Forgeloop. Keep it brief and operational.

## Project Structure
```
specs/           # Feature specifications (Forgeloop reads these)
docs/            # Product/tech docs (Forgeloop reads these)
ESCALATIONS.md   # Drafted human handoffs when Forgeloop pauses itself
src/             # Source code (adjust paths as needed)
system/knowledge # Persistent session memory (decisions, patterns, preferences, insights)
system/experts   # Domain expert guidance (architecture, security, testing, etc.)
```

## Expert Loading

Load relevant experts from `system/experts/` based on task keywords:

| Task Type | Expert File | When to Load |
|-----------|-------------|--------------|
| API/Architecture | `system/experts/architecture.md` | Schema design, component boundaries |
| Auth/Security | `system/experts/security.md` | Auth flows, encryption, vulnerability review |
| Tests/QA | `system/experts/testing.md` | Test strategy, coverage, automation |
| Code/Debug | `system/experts/implementation.md` | Refactoring, debugging, code quality |
| Deploy/CI | `system/experts/devops.md` | Pipeline, containerization, infrastructure |

**Experts provide guidance; Skills provide procedures.** Use both together for complex tasks.

## Build & Run
```bash
# TODO: Add commands for this repo
# pnpm install && pnpm dev
```

## Backpressure Commands
```bash
# Typecheck (run before committing)
# pnpm tsc --noEmit

# Tests (run before committing)
# pnpm test

# Lint (run before committing)
# pnpm lint
```

## Codebase Patterns
<!-- Add discovered patterns here as you work -->
- Prefer small, focused commits
- Update `IMPLEMENTATION_PLAN.md` when scope changes
- Use `./forgeloop/bin/ask.sh` when blocked or decisions needed
- When Forgeloop pauses itself, inspect `ESCALATIONS.md` and answer the matching item in `QUESTIONS.md`

## Modes

**Checklist Lane** (default):
- Uses `IMPLEMENTATION_PLAN.md` as the task list
- Run: `./forgeloop.sh plan` then `./forgeloop.sh build`
- Progress in `STATUS.md` and `CHANGELOG.md`

**Tasks Lane** (optional):
- Uses `prd.json` for machine-readable task tracking
- Run: `./forgeloop.sh tasks` or `./forgeloop/bin/loop-tasks.sh`
- Progress in `progress.txt`

## Important Notes
- Keep this file operational only
- Keep durable runtime rules in `docs/`, not in this file
- Status updates and progress notes belong in `IMPLEMENTATION_PLAN.md` or `progress.txt`
- A bloated AGENTS.md pollutes every future loop's context
