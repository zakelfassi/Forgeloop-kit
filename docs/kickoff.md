# Kickoff: Generate Repo-Local Specs with a Memory-Backed Agent

Forgeloop works best when `specs/` and `docs/` are high-signal and implementation-ready.

For a brand-new project, you often want a different LLM or agentic system to produce the initial spec pack before Forgeloop starts planning/building.

Forgeloop now ships a durable repo-local intake prompt for that job:

- `PROMPT_intake.md` — the reusable source prompt you can hand to any LLM/agentic system
- `docs/KICKOFF_PROMPT.md` — a rendered/shareable prompt generated from `PROMPT_intake.md`

## Recommended flow (greenfield repo)

1. Create an empty repo (or minimal scaffold).
2. Install Forgeloop into it:
   ```bash
   /path/to/forgeloop/install.sh /path/to/your/repo --wrapper
   ```
3. Use one of these two intake paths:
   - hand `PROMPT_intake.md` directly to your external LLM/agent, or
   - render a shareable prompt file:
     ```bash
     cd /path/to/your/repo
     ./forgeloop.sh kickoff "<one paragraph project brief>"
     ```
     This writes `docs/KICKOFF_PROMPT.md`.
4. Ask the external system to produce the initial repo-local spec pack.
5. Apply the output so the repo contains, at minimum:
   - `docs/README.md`
   - `specs/*.md`
   - `IMPLEMENTATION_PLAN.md`
   - `AGENTS.md` if real project-specific commands/guidance are known
6. Run Forgeloop planning/building:
   ```bash
   ./forgeloop.sh plan 1
   ./forgeloop.sh build 10
   ```

## Lane strategy

The intake prompt is deliberately checklist-first:

- **Default:** create `specs/*.md` plus `IMPLEMENTATION_PLAN.md`
- **Opt-in:** create `prd.json` only when you explicitly want the tasks lane
- **Explicit opt-in only:** create workflow-lane starter files only when you explicitly want workflow packs

That keeps phase-1 intake aligned with Forgeloop’s current canonical backlog surface.

## Customization

If you want to customize the reusable intake behavior, edit `PROMPT_intake.md`.

Do not treat `docs/KICKOFF_PROMPT.md` as the source of truth; it is a rendered artifact for sharing/pasting.

## Tips

- Keep specs outcome-focused: acceptance criteria should describe **what to verify**, not how to implement it.
- Prefer a small number of strong spec files over many vague ones.
- If you want the tasks lane, ask the external system for `prd.json` explicitly instead of assuming it by default.
- If you have a seed repo, attach it or reference its key files so the external system can reuse patterns.
