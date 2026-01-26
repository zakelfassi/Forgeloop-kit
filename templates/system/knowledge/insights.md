# Codebase Insights

Discovered facts about this specific codebase. Reduces re-discovery overhead.

## Entry Format

```markdown
### I-### | Title
- **tags**: comma, separated, tags
- **confidence**: high | medium | low
- **verified**: true | false
- **created**: YYYY-MM-DD
- **last_accessed**: YYYY-MM-DD

**Insight**: What was discovered?

**Evidence**: How was this confirmed?

**Usage**: How does this help future work?
```

---

## Insights

<!-- Add insights below this line -->

### I-001 | Example: Test Command Location
- **tags**: testing, scripts, ci
- **confidence**: high
- **verified**: true
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Insight**: Tests are run via `pnpm test` which invokes Jest with the config in `jest.config.js`.

**Evidence**: Verified by reading package.json scripts and running tests.

**Usage**: Use `pnpm test` for backpressure validation before commits.

---

### I-002 | Example: Entry Point
- **tags**: architecture, structure
- **confidence**: high
- **verified**: true
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Insight**: Main entry point is `src/index.ts`, which bootstraps the application.

**Evidence**: Verified by reading tsconfig.json and package.json.

**Usage**: Start code exploration from src/index.ts.

---

<!-- New insights are appended here by session-end.sh -->
