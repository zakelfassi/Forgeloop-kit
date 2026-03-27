# Forgeloop Docs

Start here to understand what Forgeloop actually guarantees. Read in this order:

1. `runtime-control.md` — the fail-closed contract: pauses, escalations, runtime state, and daemon behavior
2. `release-tracks.md` — v1 stable vs v2 beta: how to choose
3. `v1-to-v2-upgrade.md` — upgrading from stable to beta with commands, fallback, and rollback
4. `workflows.md` — the workflow-pack lane: layout, artifacts, runner behavior
5. `sandboxing.md` — running full-auto safely in disposable VMs/containers
6. `v2-roadmap.md` — what's shipping on v2 beta, what's deferred, what gates prod-default
7. `v2-release-checklist.md` — current ship/no-ship call, release scoreboard, and the exact beta/prod-default checklist
8. `elixir-parity-matrix.md` — bash-to-Elixir parity tracking
9. `../evals/README.md` — the public proof suite
10. `kickoff.md` — fresh-repo intake via `PROMPT_intake.md`
11. `harness-readiness.md` — repo readiness checklist for agent work
12. `../design.md` — v2 beta visual direction for the landing page and HUD

Useful commands:

```bash
./forgeloop.sh kickoff "<one paragraph project brief>"
./forgeloop.sh evals
./forgeloop.sh self-host-proof
./forgeloop.sh workflow list
./forgeloop.sh upgrade --from /path/to/newer-forgeloop-kit --force
```

Fresh repos should run `kickoff` before `plan` / `build`. Template-only installs will stop early with guidance.

Choosing between v1 and v2? Read `release-tracks.md`. Already on v1 and evaluating v2? Read `v1-to-v2-upgrade.md`. Trying to answer “are we ready to call beta or prod-default?” Read `v2-release-checklist.md`.

GCP provisioning scripts live in `ops/gcp/`.

## Additional capabilities

These ship with Forgeloop and become more useful once the core runtime is trusted:

- **Skills** — reusable workflow procedures via `sync-skills`
- **Knowledge capture** — session-based repo-local knowledge
- **Kickoff prompts** — generate specs and plans from a one-paragraph brief
- **Tasks lane** — structured `prd.json` execution
- **Workflow packs** — native workflow lane (experimental)
- **Log ingestion** — turn runtime logs into new work items
