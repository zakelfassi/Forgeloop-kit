# Forgeloop Evals

This is the **public proof suite** for Forgeloop’s safe-autonomy story.

Run it with:

```bash
./forgeloop.sh evals
```

The suite is intentionally curated around the core promise:

- **pause instead of spin** when work is blocked
- **draft reviewable escalation artifacts** for a human
- **write machine-readable runtime state**
- **keep running through provider-auth failure** when failover is enabled
- **work in both vendored and repo-root layouts**

Current proof coverage includes:

- daemon `[PAUSE]` behavior
- repeated-failure escalation
- blocker escalation
- runtime-state transitions
- LLM auth failover
- entrypoint portability across layouts

For the broader regression suite, run:

```bash
tests/run.sh
```
