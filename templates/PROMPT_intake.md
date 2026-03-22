# Forgeloop Spec Intake Prompt

You are creating the initial repo-local spec pack for a project that will be run with Forgeloop.

Your job is to produce the smallest durable set of files that lets Forgeloop start planning and building safely.

## Inspect these files first if they exist

1. `AGENTS.md`
2. `docs/README.md`
3. `specs/README.md`
4. `specs/feature_template.md`
5. `IMPLEMENTATION_PLAN.md`
6. `PROMPT_tasks.md` (only if the requester wants the tasks lane)
7. `forgeloop/templates/prd.json.example` (only if available and you need `prd.json`)
8. `forgeloop/skills/operational/prd/SKILL.md` and `forgeloop/skills/operational/tasks/SKILL.md` (only if available and you need PRD/tasks-lane structure)
9. `forgeloop/docs/workflows.md` (only if the requester explicitly wants workflow packs)

If some of these files do not exist, continue with the ones that do.

## Primary goal

Create or update a project-starting spec pack that Forgeloop can consume immediately.

Default to the **checklist lane** unless the requester explicitly asks for a different lane.

## Default outputs to create or update

Always aim to produce these files first:

- `AGENTS.md` — only if you can provide real project-specific commands, constraints, or operating guidance
- `docs/README.md` — short index of the project docs/specs
- `specs/*.md` — one or more implementation-ready spec files
- `IMPLEMENTATION_PLAN.md` — prioritized checklist backlog with explicit `REQUIRED TESTS`

## Lane strategy

### 1. Checklist lane — default

This is the default and preferred output for a new project.

Use:
- `specs/*.md`
- `IMPLEMENTATION_PLAN.md`

The checklist lane should be enough for Forgeloop to start with:
- `./forgeloop.sh plan ...`
- `./forgeloop.sh build ...`

### 2. Tasks lane — opt-in only

Only add tasks-lane artifacts if the requester explicitly asks for:
- machine-readable tasks
- autonomous task execution
- the tasks lane
- `prd.json`

When that happens, start from a human-readable PRD/spec artifact first, then add `prd.json` as the derived machine-readable task file.

If you create tasks-lane output:
- make sure the PRD/spec source and `prd.json` agree
- keep all task `passes` values set to `false`
- make tasks granular and dependency-ordered
- make every acceptance criterion machine-verifiable
- prefer boolean pass/fail criteria, commands, file checks, API checks, or browser checks
- keep `IMPLEMENTATION_PLAN.md` too unless the requester explicitly asks for tasks-lane-only output

### 3. Workflow lane — explicit opt-in only

Only create workflow seed files if the requester explicitly asks for workflow packs or workflow-lane setup.

If you create workflow-lane artifacts:
- keep them narrow and starter-level
- do not replace checklist outputs with workflow outputs
- treat workflow output as additive and experimental

## Spec-writing requirements

For each `specs/*.md` file:
- focus on one feature area or concern
- include a short summary
- include user stories when helpful
- include functional requirements
- include edge cases, failure cases, and constraints
- write acceptance criteria as observable outcomes (what to verify, not how to implement)
- be concrete enough that an implementation agent can work from the spec without guessing

Prefer a small number of strong spec files over many vague ones.

## `IMPLEMENTATION_PLAN.md` requirements

`IMPLEMENTATION_PLAN.md` must be a prioritized checklist.

For each item:
- use markdown checkboxes
- keep the item narrow enough for a focused implementation slice
- include a `REQUIRED TESTS` section derived from the acceptance criteria in the specs
- describe what must be verified, not how to implement it
- order items by dependency and impact

## `AGENTS.md` requirements

Only update `AGENTS.md` if you can add truthful, project-specific guidance such as:
- build/test commands
- architecture boundaries
- repository navigation hints
- safety constraints
- deployment or runtime caveats

Keep it concise and operational.

## `prd.json` requirements when requested

If the requester wants the tasks lane, create or update a PRD/spec source first, then create `prd.json` at repo root with:
- project name
- branch name
- short description
- ordered tasks
- `acceptanceCriteria`
- `priority`
- `passes: false`
- optional `verify_cmd`

Do not use vague criteria like:
- "works correctly"
- "review the issue"
- "document findings"

Use machine-verifiable criteria instead.

## Constraints

- Do **not** implement code.
- Do **not** invent parallel backlog or control files.
- Do **not** replace `IMPLEMENTATION_PLAN.md` with a custom planning format.
- Do **not** create `prd.json` unless it is explicitly wanted.
- Do **not** create workflow files unless they are explicitly wanted.
- Keep the result concise, high-signal, and ready for Forgeloop to consume.

## Output mode

If you can edit files directly, write the files.

If you cannot edit files directly, return exactly one unified diff / patch that creates or updates only the relevant project-starting spec files.

## Final quality bar

Before finishing, make sure:
- the checklist lane is ready by default
- the project scope and non-goals are clear
- acceptance criteria are observable and testable
- `IMPLEMENTATION_PLAN.md` points at the next sensible slices
- optional tasks/workflow outputs appear only when explicitly requested
