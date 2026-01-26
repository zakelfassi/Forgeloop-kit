# Knowledge Index

Session-to-session memory for Ralph. This index provides quick access to learned knowledge.

## Quick Stats
- Decisions: 0
- Patterns: 0
- Preferences: 0
- Insights: 0
- Archived: 0

## Tag Index

<!-- Stats are maintained by session-end.sh; tag index is optional/manual for now -->
<!-- Suggested format: tag → file:ID, file:ID, ... -->

| Tag | Entries |
|-----|---------|
| <!-- Tags will appear here --> |

## Recent Entries (Last 10)

<!-- Optional/manual for now -->
<!-- Suggested format: ID | Type | Summary | Last Accessed -->

| ID | Type | Summary | Last Accessed |
|----|------|---------|---------------|
| <!-- Recent entries will appear here --> |

## Retrieval Guide

1. **By Tag**: `rg -l "\\*\\*tags\\*\\*:[^\\n]*\\b<tag>\\b" system/knowledge/*.md` (or `grep -l "<tag>" system/knowledge/*.md`)
2. **By ID**: `rg -l "<ID>" system/knowledge/*.md` (or `grep -l "<ID>" system/knowledge/*.md`)
3. **By Recency**: Check this index's "Recent Entries" table
4. **By Confidence**: Filter entries with `**confidence**: high` (or `confidence: high`)

## Decay Policy

- **Active**: Accessed within 30 days
- **Stale**: 31-90 days without access (flagged for review)
- **Archive**: 90+ days or unverified after 60 days → flagged for review / consider archiving

## Integration Points

- **Session Start**: Load high-confidence entries from decisions.md, patterns.md, preferences.md
- **Session End**: Update "Last Accessed" dates, capture new knowledge
- **REQUESTS.md**: Add `[KNOWLEDGE_SYNC]` flag to trigger knowledge capture
