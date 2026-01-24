---
name: skillforge
description: "Scaffold a new reusable Skill (SKILL.md + optional scripts/references/assets). Use when asked to create a new skill, when a task would benefit from a reusable procedural guide, or when you notice repeated workflow friction."
---

# SkillForge

Create well-formed Skills quickly and consistently.

## Workflow

1. Restate the spec
   - What problem does the skill solve?
   - Who/what will use it (Codex, Claude Code, humans)?
   - What inputs does it take and what outputs does it produce?
   - What is explicitly out of scope?

2. Pick the skill type
   - `operational`: narrowly-scoped, repeatable procedure (preferred default).
   - `meta`: orchestration / governance / decision-making.
   - `composed`: "manager" skills that chain other skills together.

3. Name the skill
   - `kebab-case`, short, verb-led if possible.
   - One responsibility per skill.

4. Create the skill folder
   - Recommended (project skills): `skills/<type>/<name>/`
   - Optional (kit skills): `ralph/skills/<type>/<name>/` only when you are changing the kit itself
   - Required: `SKILL.md`
   - Optional: `scripts/`, `references/`, `assets/`

5. Write `SKILL.md`
   - Frontmatter: `name` + `description` only.
   - The `description` is the trigger surface: include what it does + when to use it.
   - Body: concise steps + crisp examples; link large details into `references/`.

6. Sync skills into your agents
   - After adding/updating skills, run:
     - `./ralph/bin/sync-skills.sh` (Claude Code mirror + optional Codex install)

## Minimal SKILL.md skeleton

```md
---
name: your-skill-name
description: "What it does. Use when … (include triggers)."
---

# Your Skill Name

## Inputs
- …

## Outputs
- …

## Steps
1. …

## Examples
- …
```

## Guardrails
- Prefer small, reversible changes.
- Do not "over-forge": only create a new skill when it will be reused or it meaningfully reduces future context.
