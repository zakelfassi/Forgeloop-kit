# Architectural Decisions

Captured decisions that inform future work. Each entry represents a deliberate choice with context and rationale.

## Entry Format

```markdown
### D-### | Title
- **tags**: comma, separated, tags
- **confidence**: high | medium | low
- **verified**: true | false
- **created**: YYYY-MM-DD
- **last_accessed**: YYYY-MM-DD

**Context**: Why was this decision made?

**Decision**: What was decided?

**Consequences**: What are the tradeoffs?
```

---

## Decisions

<!-- Add decisions below this line -->

### D-001 | Example: Use Ralph for Build Orchestration
- **tags**: tooling, ci, automation
- **confidence**: high
- **verified**: true
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Context**: Needed consistent build orchestration across projects with multi-model routing.

**Decision**: Adopt Ralph-Kit as the primary build loop framework.

**Consequences**:
- (+) Consistent patterns across repos
- (+) Multi-model routing (Claude, Codex)
- (-) Learning curve for new team members

---

<!-- New decisions are appended here by session-end.sh -->
