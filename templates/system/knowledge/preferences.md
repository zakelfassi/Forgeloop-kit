# User Preferences

Explicitly stated preferences from the user. These take priority over inferred patterns.

## Entry Format

```markdown
### PR-### | Title
- **tags**: comma, separated, tags
- **source**: explicit | inferred
- **created**: YYYY-MM-DD
- **last_accessed**: YYYY-MM-DD

**Preference**: What does the user prefer?

**Application**: When/how to apply this preference?
```

---

## Preferences

<!-- Add preferences below this line -->

### PR-001 | Example: Use PNPM for Node.js Projects
- **tags**: tooling, node, package-manager
- **source**: explicit
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Preference**: Always use PNPM instead of npm or yarn for Node.js projects.

**Application**:
- Install commands: `pnpm install`
- Add dependencies: `pnpm add <package>`
- Scripts: `pnpm run <script>`

---

### PR-002 | Example: No Co-Authored-By in Commits
- **tags**: git, commits, style
- **source**: explicit
- **created**: 2025-01-01
- **last_accessed**: 2025-01-01

**Preference**: Never include "Co-Authored-By" lines in git commit messages.

**Application**: Omit co-author attribution when committing.

---

<!-- New preferences are appended here by session-end.sh -->
