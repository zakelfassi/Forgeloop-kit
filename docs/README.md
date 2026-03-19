# Forgeloop Docs

Start here, in this order:

1. `runtime-control.md` — the fail-closed runtime contract: supported daemon flags, escalation artifacts, and runtime-state semantics
2. `sandboxing.md` — how to run full-auto safely in a disposable VM/container
3. `v2-roadmap.md` — bash vs Elixir coexistence, milestone ordering, and current deferrals
4. `elixir-parity-matrix.md` — the current bash-to-Elixir proof matrix
5. `../evals/README.md` — the public proof suite for the safe-autonomy story
6. `kickoff.md` — greenfield workflow for generating initial `docs/*` + `specs/*`
7. `harness-readiness.md` — repo-local checklist for agent legibility, reproducibility, and failure handling
8. `pr-triage-2026-03-05.md` — current PR triage notes

Useful commands:

```bash
./forgeloop.sh evals
./forgeloop.sh upgrade --from /path/to/newer-forgeloop-kit --force
```

GCP provisioning scripts live in `ops/gcp/`.

## Secondary systems

Forgeloop also ships systems that compound on top of the control plane:

- Skills / `sync-skills`
- repo-local knowledge capture
- domain experts
- kickoff prompts
- structured tasks lane
- report / log ingestion

They are real capabilities, but the runtime contract above is the primary trust surface.
