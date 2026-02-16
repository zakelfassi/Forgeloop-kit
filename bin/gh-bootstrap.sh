#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Bootstrap GitHub as the source of truth for a repo:
- Create (or attach to) a private GitHub repo
- Create a GitHub Project (v2) to act as the roadmap
- Seed baseline roadmap issues and add them to the project
- Persist project/repo metadata locally (default: .forgeloop/gh.json)

Usage:
  ./forgeloop/bin/gh-bootstrap.sh [--owner <login>] [--repo <name>] [--project-title <title>] [--no-issues]

Examples:
  ./forgeloop/bin/gh-bootstrap.sh --owner zakelfassi --repo memory-app --project-title "Memory App Roadmap"
  ./forgeloop/bin/gh-bootstrap.sh --owner @me

Notes:
- Requires: gh, jq, git
- Your gh token must have: repo, project scopes
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/core.sh"

REPO_DIR="$(forgeloop_core__resolve_repo_dir "$0")"
forgeloop_core__load_config "$REPO_DIR"

forgeloop_core__require_cmd gh
forgeloop_core__require_cmd jq
forgeloop_core__require_cmd git

OWNER="${FORGELOOP_GH_OWNER:-}"
REPO_NAME="${FORGELOOP_GH_REPO:-$(basename "$REPO_DIR")}"
PROJECT_TITLE="${FORGELOOP_GH_PROJECT_TITLE:-}"
SEED_ISSUES="true"
FORCE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --owner)
      OWNER="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_NAME="${2:-}"
      shift 2
      ;;
    --project-title)
      PROJECT_TITLE="${2:-}"
      shift 2
      ;;
    --no-issues)
      SEED_ISSUES="false"
      shift
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$OWNER" ]] || [[ "$OWNER" == "@me" ]]; then
  OWNER="$(gh api user --jq .login)"
fi

if [[ -z "$REPO_NAME" ]]; then
  echo "Error: --repo is required (or set FORGELOOP_GH_REPO)" >&2
  exit 1
fi

if [[ -z "$PROJECT_TITLE" ]]; then
  PROJECT_TITLE="$REPO_NAME Roadmap"
fi

RUNTIME_DIR="$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")"
GH_FILE="$RUNTIME_DIR/gh.json"

if [[ -f "$GH_FILE" && "$FORCE" != "true" ]]; then
  echo "Error: $GH_FILE already exists; refusing to re-bootstrap (pass --force to overwrite)." >&2
  exit 1
fi

REMOTE_NAME="${FORGELOOP_GIT_REMOTE:-origin}"
FULL_REPO="$OWNER/$REPO_NAME"

# Ensure we have a git repo and at least one commit before creating/pushing
if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  (cd "$REPO_DIR" && git init -b "${FORGELOOP_DEFAULT_BRANCH:-main}")
fi

# Creating a first commit automatically can accidentally capture huge build artifacts
# (e.g. node_modules/) if the repo doesn't have a proper .gitignore yet.
if ! git -C "$REPO_DIR" rev-parse HEAD >/dev/null 2>&1; then
  if [[ "$FORCE" != "true" ]]; then
    check_not_tracked_heavy() {
      local p="$1"
      local label="$2"
      if [[ -e "$REPO_DIR/$p" ]] && ! git -C "$REPO_DIR" check-ignore -q "$p" 2>/dev/null; then
        echo "Error: '$p' exists and is not gitignored. Refusing to auto-create an initial commit (would likely commit $label)." >&2
        echo "Fix: add it to .gitignore (or delete it), then re-run. (Override with --force if you really want this.)" >&2
        exit 2
      fi
    }

    check_not_tracked_heavy "node_modules" "dependencies"
    check_not_tracked_heavy "dist" "build output"
    check_not_tracked_heavy ".output" "build output"
    check_not_tracked_heavy ".tanstack" "build cache"
    check_not_tracked_heavy "uploads" "local uploads"
    check_not_tracked_heavy "sqlite.db" "local database"
  fi

  (cd "$REPO_DIR" && git add -A)

  local_count="$(git -C "$REPO_DIR" diff --cached --name-only | wc -l | tr -d ' ')"
  if [[ "$FORCE" != "true" ]] && [[ "$local_count" -gt 5000 ]]; then
    git -C "$REPO_DIR" reset >/dev/null 2>&1 || true
    echo "Error: initial commit would include $local_count files; refusing (pass --force to override)." >&2
    exit 2
  fi

  (cd "$REPO_DIR" && git commit -m "chore: initial commit" --allow-empty)
fi

# Create or attach repo
REPO_URL=""
if gh repo view "$FULL_REPO" --json url >/dev/null 2>&1; then
  REPO_URL="$(gh repo view "$FULL_REPO" --json url --jq .url)"
else
  echo "Creating private repo: $FULL_REPO"
  # gh repo create will add a remote and optionally push
  (cd "$REPO_DIR" && gh repo create "$FULL_REPO" --private --source . --remote "$REMOTE_NAME" --push)
  REPO_URL="$(gh repo view "$FULL_REPO" --json url --jq .url)"
fi

# Ensure remote points at the created repo (best-effort)
if git -C "$REPO_DIR" remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  true
else
  (cd "$REPO_DIR" && git remote add "$REMOTE_NAME" "$REPO_URL")
fi

# Create project v2
echo "Creating GitHub Project v2: $PROJECT_TITLE (owner: $OWNER)"
PROJECT_JSON="$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json)"
PROJECT_NUMBER="$(echo "$PROJECT_JSON" | jq -r '.number')"
PROJECT_URL="$(echo "$PROJECT_JSON" | jq -r '.url')"
PROJECT_ID="$(echo "$PROJECT_JSON" | jq -r '.id')"

# Seed baseline roadmap issues
ISSUES_JSON="[]"
if [[ "$SEED_ISSUES" == "true" ]]; then
  echo "Seeding baseline issues and adding to project #$PROJECT_NUMBER..."

  create_issue_and_add() {
    local title="$1"
    local body="$2"

    local issue_url
    issue_url="$(gh issue create -R "$FULL_REPO" --title "$title" --body "$body")"

    # Add to project (by URL)
    gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$issue_url" >/dev/null

    local issue_number
    issue_number="$(basename "$issue_url")"

    ISSUES_JSON="$(jq -c --arg title "$title" --arg url "$issue_url" --arg number "$issue_number" '. + [{title:$title,url:$url,number:($number|tonumber)}]' <<<"$ISSUES_JSON")"
  }

  create_issue_and_add "Roadmap: Setup" $'Scope:\n- [ ] Repo local dev instructions\n- [ ] CI gate (lint/typecheck/test/build)\n- [ ] Deploy runbook + rollback\n\nAcceptance:\n- One-command local run\n- CI green on default branch\n- Deploy can be verified + rolled back' 

  create_issue_and_add "Roadmap: Auth" $'Scope:\n- [ ] Auth strategy selected (sessions/JWT/etc)\n- [ ] Threat model + basic hardening\n- [ ] Access control tests\n\nAcceptance:\n- Anonymous vs authed flows defined\n- Privileged actions protected\n- Security review checklist completed' 

  create_issue_and_add "Roadmap: Observability" $'Scope:\n- [ ] Request logging (PII-safe)\n- [ ] Error tracking / structured logs\n- [ ] Health checks\n\nAcceptance:\n- Errors are actionable with context\n- Health endpoint verifies dependencies\n- Logs support incident triage' 

  create_issue_and_add "Roadmap: Demo checklist" $'Scope:\n- [ ] Happy-path demo script\n- [ ] Edge-case demo (failure modes)\n- [ ] Regression checks (redirects, styling, auth)\n\nAcceptance:\n- Demo can be run end-to-end in <5 minutes\n- Known regression checks are documented and repeatable' 
fi

mkdir -p "$RUNTIME_DIR"

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg schemaVersion "1" \
  --arg createdAt "$CREATED_AT" \
  --arg owner "$OWNER" \
  --arg repo "$REPO_NAME" \
  --arg repoUrl "$REPO_URL" \
  --arg projectTitle "$PROJECT_TITLE" \
  --arg projectUrl "$PROJECT_URL" \
  --arg projectId "$PROJECT_ID" \
  --argjson projectNumber "$PROJECT_NUMBER" \
  --argjson seedIssues "$ISSUES_JSON" \
  '{schemaVersion: ($schemaVersion|tonumber), createdAt:$createdAt, owner:$owner, repo:$repo, repoUrl:$repoUrl, project:{number:$projectNumber,title:$projectTitle,url:$projectUrl,id:$projectId}, seedIssues:$seedIssues}' \
  > "$GH_FILE"

echo "Wrote: $GH_FILE"
echo "Repo:    $REPO_URL"
echo "Project: $PROJECT_URL"
