# Ralph Kit Docs

- `kickoff.md` — greenfield workflow to generate `docs/*` + `specs/*` using a memory-backed agent, then hand off to Ralph.
- `sandboxing.md` — how to run Ralph in full-auto safely (Docker fallback + cloud VM notes + pricing table).

GCP provisioning scripts live in `ops/gcp/`.

## Skills-Driven Development (SDD)

Ralph is already a loop. **Skills-Driven Development** adds a pre-step: before you implement the next task, decide if the work would benefit from a reusable **Skill** (a small, focused SOP for an agent). If yes, forge the skill, sync it, then continue.

**Why:** fewer “prompt one-offs”, more repeatable delivery. Over time you build a repo-specific **skill factory** (including “middle-management” composed skills that coordinate other skills).

**Where skills live:**
- Project (recommended): `skills/<operational|meta|composed>/<skill-name>/SKILL.md`
- Kit (shipped): `ralph/skills/<operational|meta|composed>/<skill-name>/SKILL.md` (avoid editing unless you’re changing the kit itself)
`sync-skills` links kit + project skills into `.claude/skills` (Claude Code) and, when writable, `.codex/skills` (Codex).

**Repo hygiene:** commit `.claude/skills/` so the same skills are available for everyone. If you want Codex to discover repo skills without a user-level install, also commit `.codex/skills/`. Keep RepoPrompt-only skills prefixed `rp-` and ignore `.claude/skills/rp-*` (and `.codex/skills/rp-*` if you mirror Codex too).

**Naming:** keep skill folder names unique across all types (`operational/`, `meta/`, `composed/`). Mirrors use the leaf folder name, so duplicates will collide.

**Sync into agents:**
```bash
./ralph.sh sync-skills # refreshes repo-scoped skill mirrors (Codex mirror is best-effort if .codex is not writable)

# Optional: also install into user-level skill dirs (if present)
./ralph.sh sync-skills --claude-global --codex-global
# or: ./ralph.sh sync-skills --all
```
If you didn’t install the `ralph.sh` wrapper, run: `./ralph/bin/sync-skills.sh`.

## Decision Tree

Use this to pick the right workflow for your situation:

```mermaid
flowchart TD
    A{Starting from scratch?}
    A -->|Yes| B[Use KICKOFF]
    A -->|No| C{Have existing specs?}

    B --> B1["./ralph.sh kickoff 'project brief'"]
    B1 --> D{Want human review?}

    C -->|Yes| D
    C -->|No| C1[Write specs/* manually]
    C1 --> D

    D -->|Yes| E[CHECKLIST LANE]
    D -->|No| F[TASKS LANE]

    E --> E1["./ralph.sh plan 1<br/>./ralph.sh build 10"]
    F --> F1["./ralph.sh tasks 10"]

    E1 --> G{Want continuous automation?}
    F1 --> G

    G -->|Yes| H[DAEMON MODE]
    G -->|No| I[Run loops manually]

    H --> H1["./ralph.sh daemon 300"]
```

## Shared Libraries

The kit includes shared bash libraries under `lib/`:

### lib/core.sh

Core utilities for logging, notifications, and git operations.

| Function | Description |
|----------|-------------|
| `ralph_core__log LEVEL MSG` | Timestamped logging. Levels: `info`, `warn`, `error` |
| `ralph_core__notify MSG` | Send Slack notification (requires `SLACK_WEBHOOK_URL` in `.env.local`) |
| `ralph_core__git_push_branch BRANCH` | Safe branch push with conflict detection and retry |
| `ralph_core__consume_flag FLAG` | Read and atomically clear a flag from `REQUESTS.md` |
| `ralph_core__hash_content FILE` | SHA256 hash for idempotency checks |
| `ralph_core__ensure_gitignore PATTERN` | Add pattern to `.gitignore` if not present |

### lib/llm.sh

Unified LLM execution with failover and rate-limiting.

| Function | Description |
|----------|-------------|
| `ralph_llm__run MODEL PROMPT [OPTS]` | Execute prompt via claude or codex CLI |
| `ralph_llm__with_failover PRIMARY FALLBACK PROMPT` | Try primary model, fall back on failure |
| `ralph_llm__structured MODEL PROMPT SCHEMA` | Get structured JSON output |

**Features:**
- Automatic model failover (e.g., claude → codex)
- Rate-limiting with exponential backoff
- Structured output support via JSON schemas
- Optional Codex security/review gates

**Example:**
```bash
source "$RALPH_DIR/lib/llm.sh"

# Simple execution
ralph_llm__run claude "Explain this error: $ERROR"

# With failover
ralph_llm__with_failover codex claude "Review this PR"

# Structured output
ralph_llm__structured claude "Analyze code quality" review.schema.json
```

Scripts in `bin/` source these libraries for consistent behavior across loops.

## Workflow Lanes

Ralph supports two workflow lanes:

### Checklist Lane (default)
Uses `IMPLEMENTATION_PLAN.md` as the task list with markdown checkboxes.

```bash
./ralph.sh plan 1    # Generate plan
./ralph.sh build 10  # Execute up to 10 iterations
```

**Best for:** Human-in-the-loop workflows where you want to review, edit, or reorder tasks.

### Tasks Lane (opt-in)
Uses `prd.json` for machine-readable task tracking with `passes: true/false` flags.

```bash
./ralph.sh tasks 10  # Execute prd.json tasks
```

**Best for:** Full automation where tasks are well-defined and don't need human review.

Progress is tracked in `progress.txt` with task completion status.

## Daemon Mode

The daemon (`ralph-daemon.sh`) runs loops automatically, monitoring for:
- Git changes (new commits, remote updates)
- `REQUESTS.md` modifications
- Control flags

**Control flags** (add to `REQUESTS.md`):
- `[PAUSE]` — Halt daemon until removed
- `[REPLAN]` — Trigger re-planning pass
- `[DEPLOY]` — Run `RALPH_DEPLOY_CMD` after successful build
- `[INGEST_LOGS]` — Analyze logs into a new request (configure `RALPH_INGEST_LOGS_CMD` or `RALPH_INGEST_LOGS_FILE`)

**Blocker detection:** The daemon detects when the agent is stuck (e.g., unanswered questions) and pauses to prevent spam loops.

## Skills

Ralph Kit includes a small Skills library (in `ralph/skills/`) you can use to standardize planning/execution workflows:

- `ralph-prd` — generate Product Requirements Documents
- `ralph-tasks` — convert PRDs to machine-executable `prd.json`
- `ralph-skillforge` — scaffold new reusable Skills
- `ralph-project-architect` — turn a brief into a concrete plan (incl. skill opportunities)
- `ralph-completion-director` — run an execution loop with locks/gates
- `ralph-builder-loop` — composed end-to-end build loop

Install into user-level agent skill dirs (when present): `./install.sh /path/to/repo --wrapper --skills`

For Claude Code per-repo discovery (no global install), run this in the target repo:
`./ralph/bin/sync-skills.sh` (creates/refreshes `.claude/skills` and, when writable, `.codex/skills` symlinks).
