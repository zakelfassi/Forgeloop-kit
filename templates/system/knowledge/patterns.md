# Observed Patterns

Behavioral patterns discovered during work. These inform how Ralph approaches similar tasks.

## Entry Format

```markdown
### P-### | Title
- **tags**: comma, separated, tags
- **strength**: strong | moderate | weak
- **occurrences**: number of times observed
- **created**: YYYY-MM-DD
- **last_accessed**: YYYY-MM-DD

**Pattern**: What behavior was observed?

**Context**: When does this pattern apply?

**Implications**: How should this inform future work?
```

---

## Patterns

<!-- Add patterns below this line -->

### P-001 | Example: Small Commits Improve Review Velocity
- **tags**: git, workflow, review
- **strength**: strong
- **occurrences**: 50+
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Pattern**: Commits under 200 lines get reviewed and merged faster than larger commits.

**Context**: PR reviews, CI pipelines, team collaboration.

**Implications**:
- Prefer incremental commits
- Split large features into smaller PRs
- Use feature flags for incomplete work

---

<!-- New patterns are appended here by session-end.sh -->
