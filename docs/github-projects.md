# GitHub as Source of Truth (Repo + Project v2)

This workflow treats a **GitHub Project (v2)** as the authoritative roadmap.
Local planning files are **derived views** generated from GitHub.

## Prereqs

- GitHub CLI installed + authenticated:
  ```bash
  gh auth status
  ```
- Token scopes:
  - `repo`
  - `project`

If needed:
```bash
gh auth refresh -s repo -s project
```

## 1) Install Forgeloop into your repo

From inside your repo:
```bash
/path/to/Forgeloop-kit/install.sh . --wrapper
```

Or if Forgeloop is already vendored at `./forgeloop`:
```bash
./forgeloop/install.sh --wrapper
```

## 2) Bootstrap GitHub repo + Project

From the repo root:
```bash
./forgeloop/bin/gh-bootstrap.sh --owner @me --repo "$(basename "$PWD")" --project-title "$(basename "$PWD") Roadmap"
```

This will:
- Create a private GitHub repo (if it doesn’t exist)
- Create a GitHub Project (v2)
- Seed baseline roadmap issues and add them to the project
- Write `.forgeloop/gh.json`

### Notes on `.forgeloop/gh.json`

The installer configures `.gitignore` to ignore runtime artifacts but allow committing:
- `.forgeloop/gh.json`
- `.forgeloop/project-cache/**`

Commit `gh.json` so other machines/agents can sync the roadmap.

## 3) One-way sync: GitHub Project -> local markdown

```bash
./forgeloop/bin/gh-sync-project.sh
```

Outputs (derived artifacts):
- `ROADMAP.md`
- `TODAY.md`
- `BACKLOG.md`

## Suggested convention

- Treat GitHub Project as the source of truth for statuses and prioritization.
- Treat the generated markdown files as **read-only views** (commit them if you want them in-repo).
- Keep automation one-way (GitHub -> local) to avoid merge/conflict complexity.
