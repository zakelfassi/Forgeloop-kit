# Forgeloop Docs

Start here, in this order:

1. `runtime-control.md` — the fail-closed runtime contract: supported daemon flags, escalation artifacts, runtime-state semantics, and the current limits of planned self-hosting isolation
2. `release-tracks.md` — stable `v1.0.0` vs `main` as the current v2 alpha/development track, plus the upgrade/evaluation path between them
3. `../design.md` — current visual brief for the landing page and operator HUD on the v2 alpha track
4. `workflows.md` — the detailed workflow-lane contract: repo layout, artifact behavior, compatibility notes, and checkpoint cadence
5. `sandboxing.md` — how to run full-auto safely in a disposable VM/container, plus the future repo-internal worktree layer
6. `v2-roadmap.md` — the mainline v2 alpha roadmap: bash vs Elixir coexistence, milestone ordering, planned self-hosting supervision, workflow migration direction, and current deferrals
7. `elixir-parity-matrix.md` — the current bash-to-Elixir proof matrix
8. `../evals/README.md` — the public proof suite for the safe-autonomy story
9. `kickoff.md` — greenfield workflow for the reusable `PROMPT_intake.md` surface and generated `docs/KICKOFF_PROMPT.md`
10. `harness-readiness.md` — repo-local checklist for agent legibility, reproducibility, failure handling, and the next self-hosting proof gaps
11. `pr-triage-2026-03-05.md` — current PR triage notes

Useful commands:

```bash
./forgeloop.sh kickoff "<one paragraph project brief>"
./forgeloop.sh evals
./forgeloop.sh self-host-proof
./forgeloop.sh workflow list
./forgeloop.sh upgrade --from /path/to/newer-forgeloop-kit --force
```

Fresh bootstrap repos should use `kickoff` before checklist `plan` / `build`; template-only installs are now blocked with explicit intake guidance until real docs/specs/plan content exists.

If you are deciding between the stable release and current mainline, read `release-tracks.md` before treating the V2 work as beta- or parity-level ready.

If you are changing the landing page or operator HUD, read `../design.md` first so the visual system stays coherent with the current v2 alpha launch story.

GCP provisioning scripts live in `ops/gcp/`.

## Secondary systems

Forgeloop also ships systems that compound on top of the control plane:

- Skills / `sync-skills`
- repo-local knowledge capture
- domain experts
- kickoff prompts
- structured tasks lane
- workflow packs / workflow-pack lane
- report / log ingestion

They are real capabilities, but the runtime contract above is the primary trust surface.
