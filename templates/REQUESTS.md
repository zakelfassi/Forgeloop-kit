# User Requests

Add requests below. Forgeloop will process them in order.

## Format

```
## [Request Title]
- Priority: high/medium/low
- Type: feature/fix/refactor/docs

Description of what you want...

### Acceptance Criteria
- Specific, verifiable criterion 1
- Specific, verifiable criterion 2
```

## Daemon Control Flags

Add these anywhere in this file to control the Forgeloop daemon:

- `[PAUSE]` - Pause the daemon loop
- `[REPLAN]` - Run planning once, then continue building
- `[DEPLOY]` - Run the configured deploy command
- `[INGEST_LOGS]` - Analyze configured logs and append a new request (see `./forgeloop/bin/ingest-logs.sh`)

Forgeloop may also insert `[PAUSE]` automatically when it escalates a repeated failure or blocker and needs human input.

## Ingested Reports & Logs

When using `./forgeloop/bin/ingest-report.sh` or `./forgeloop/bin/ingest-logs.sh`, entries are appended below with:
- `Source: report:<hash>` - For idempotency tracking
- `Source: logs:<hash>` - For idempotency tracking
- `Signature: logsig:<hash>` - Best-effort dedupe for repeated runtime errors
- `CreatedAt: <timestamp>` - When ingested

---

<!-- Add your requests below this line -->
