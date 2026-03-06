# Forgeloop Evals

Run the scenario harness with:

```bash
./forgeloop.sh evals
```

Current scenarios cover:

- Vendored and repo-root entrypoint layout resolution
- Repeated failure escalation into `QUESTIONS.md` / `ESCALATIONS.md`
- Explicit runtime state transitions (`running`, `blocked`, `awaiting-human`, `recovered`, `idle`)
- Daemon blocker escalation instead of indefinite sleep/retry
- In-place kit upgrades for existing vendored repos
