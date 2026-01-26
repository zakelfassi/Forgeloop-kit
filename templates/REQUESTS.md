# User Requests

Add requests below. Ralph will process them in order.

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

Add these anywhere in this file to control the Ralph daemon:

- `[PAUSE]` - Pause the daemon loop
- `[REPLAN]` - Run planning once, then continue building
- `[DEPLOY]` - Run the configured deploy command
- `[INGEST_LOGS]` - Analyze configured logs and append a new request (see `./ralph/bin/ingest-logs.sh`)
- `[KNOWLEDGE_SYNC]` - Capture knowledge from session to `system/knowledge/`

## Ingested Reports & Logs

When using `./ralph/bin/ingest-report.sh` or `./ralph/bin/ingest-logs.sh`, entries are appended below with:
- `Source: report:<hash>` - For idempotency tracking
- `Source: logs:<hash>` - For idempotency tracking
- `Signature: logsig:<hash>` - Best-effort dedupe for repeated runtime errors
- `CreatedAt: <timestamp>` - When ingested

---

<!-- Add your requests below this line -->
