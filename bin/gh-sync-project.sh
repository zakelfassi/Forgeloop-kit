#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Sync a GitHub Project (v2) into local, derived markdown views.

Reads project metadata from .forgeloop/gh.json (created by gh-bootstrap.sh), pulls items via GraphQL,
then generates:
- ROADMAP.md  (grouped by Status)
- TODAY.md    (items in progress)
- BACKLOG.md  (items in backlog/todo)

Usage:
  ./forgeloop/bin/gh-sync-project.sh [--owner <login>] [--project <number>]

Examples:
  ./forgeloop/bin/gh-sync-project.sh
  ./forgeloop/bin/gh-sync-project.sh --owner zakelfassi --project 3

Notes:
- Requires: gh, jq
- One-way sync (GitHub -> local). Treat output files as derived artifacts.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/core.sh"

REPO_DIR="$(forgeloop_core__resolve_repo_dir "$0")"
forgeloop_core__load_config "$REPO_DIR"

forgeloop_core__require_cmd gh
forgeloop_core__require_cmd jq

RUNTIME_DIR="$(forgeloop_core__ensure_runtime_dirs "$REPO_DIR")"
GH_FILE="$RUNTIME_DIR/gh.json"

OWNER_OVERRIDE=""
PROJECT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --owner)
      OWNER_OVERRIDE="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT_OVERRIDE="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$GH_FILE" ]]; then
  echo "Error: missing $GH_FILE. Run ./forgeloop/bin/gh-bootstrap.sh first." >&2
  exit 1
fi

OWNER="$(jq -r '.owner // empty' "$GH_FILE")"
PROJECT_NUMBER="$(jq -r '.project.number // empty' "$GH_FILE")"
PROJECT_TITLE="$(jq -r '.project.title // "Roadmap"' "$GH_FILE")"
PROJECT_URL="$(jq -r '.project.url // empty' "$GH_FILE")"

if [[ -n "$OWNER_OVERRIDE" ]]; then OWNER="$OWNER_OVERRIDE"; fi
if [[ -n "$PROJECT_OVERRIDE" ]]; then PROJECT_NUMBER="$PROJECT_OVERRIDE"; fi

if [[ -z "$OWNER" ]] || [[ -z "$PROJECT_NUMBER" ]] || [[ "$PROJECT_NUMBER" == "null" ]]; then
  echo "Error: could not determine owner/project number (gh.json missing fields)" >&2
  exit 1
fi

CACHE_DIR="$RUNTIME_DIR/project-cache"
mkdir -p "$CACHE_DIR"
RAW_JSON="$CACHE_DIR/project-items.json"

QUERY='query($owner:String!, $number:Int!, $after:String) {
  repositoryOwner(login:$owner) {
    __typename
    ... on User {
      projectV2(number:$number) {
        id
        title
        url
        items(first:100, after:$after) {
          nodes {
            id
            type
            content {
              __typename
              ... on Issue {
                number
                title
                url
                repository { nameWithOwner }
              }
              ... on PullRequest {
                number
                title
                url
                repository { nameWithOwner }
              }
            }
            fieldValues(first:50) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2SingleSelectField { name } }
                }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    ... on Organization {
      projectV2(number:$number) {
        id
        title
        url
        items(first:100, after:$after) {
          nodes {
            id
            type
            content {
              __typename
              ... on Issue {
                number
                title
                url
                repository { nameWithOwner }
              }
              ... on PullRequest {
                number
                title
                url
                repository { nameWithOwner }
              }
            }
            fieldValues(first:50) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  field { ... on ProjectV2SingleSelectField { name } }
                }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}'

# Paginate
ALL_ITEMS='[]'
AFTER=""
while true; do
  if [[ -n "$AFTER" ]]; then
    RESP="$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F number="$PROJECT_NUMBER" -F after="$AFTER")"
  else
    RESP="$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F number="$PROJECT_NUMBER")"
  fi
  PROJECT_NODE="$(echo "$RESP" | jq -c '.data.repositoryOwner.projectV2')"
  if [[ "$PROJECT_NODE" == "null" ]]; then
    echo "Error: could not load project v2 owner=$OWNER number=$PROJECT_NUMBER" >&2
    exit 1
  fi

  PAGE_ITEMS="$(echo "$PROJECT_NODE" | jq -c '.items.nodes')"
  ALL_ITEMS="$(jq -c --argjson page "$PAGE_ITEMS" '. + $page' <<<"$ALL_ITEMS")"

  HAS_NEXT="$(echo "$PROJECT_NODE" | jq -r '.items.pageInfo.hasNextPage')"
  if [[ "$HAS_NEXT" != "true" ]]; then
    # refresh title/url from remote if present
    PROJECT_TITLE="$(echo "$PROJECT_NODE" | jq -r '.title')"
    PROJECT_URL="$(echo "$PROJECT_NODE" | jq -r '.url')"
    break
  fi
  AFTER="$(echo "$PROJECT_NODE" | jq -r '.items.pageInfo.endCursor')"
  [[ "$AFTER" == "null" ]] && break
  sleep 0.2
done

# Normalize items: title, url, repo, number, status
NORMALIZED="$(jq -c '
  map({
    id: .id,
    type: .type,
    contentType: (.content.__typename // "Draft"),
    title: (.content.title // "(draft item)"),
    url: (.content.url // ""),
    number: (.content.number // null),
    repo: (.content.repository.nameWithOwner // ""),
    status: (
      (.fieldValues.nodes
        | map(select(.__typename=="ProjectV2ItemFieldSingleSelectValue")
              | select(.field.name=="Status")
              | .name)
        | .[0]) // ""
    )
  })
' <<<"$ALL_ITEMS")"

jq -n \
  --arg owner "$OWNER" \
  --argjson projectNumber "$PROJECT_NUMBER" \
  --arg projectTitle "$PROJECT_TITLE" \
  --arg projectUrl "$PROJECT_URL" \
  --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson items "$NORMALIZED" \
  '{owner:$owner, project:{number:$projectNumber, title:$projectTitle, url:$projectUrl}, fetchedAt:$fetchedAt, items:$items}' \
  > "$RAW_JSON"

echo "Wrote cache: $RAW_JSON"

# Markdown generators
GEN_HEADER() {
  cat <<EOF
<!--
  GENERATED FILE — DO NOT EDIT.
  Source of truth: GitHub Project v2
  Owner: $OWNER
  Project: $PROJECT_TITLE (#$PROJECT_NUMBER)
  URL: $PROJECT_URL
  Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
  Generated by: ./forgeloop/bin/gh-sync-project.sh
-->

EOF
}

write_grouped_by_status() {
  local out="$1"
  {
    GEN_HEADER
    echo "# $PROJECT_TITLE"
    echo ""

    local statuses
    statuses=$(jq -r '.items[].status' "$RAW_JSON" | sed '/^$/d' | sort -u)

    if [[ -z "$statuses" ]]; then
      echo "(No items with Status field found.)"
      echo ""
      echo "Project: $PROJECT_URL"
      return 0
    fi

    while IFS= read -r status; do
      [[ -z "$status" ]] && continue
      echo "## $status"
      echo ""
      jq -r --arg status "$status" '.items[] | select(.status==$status) | "- [ ] \(.title)" + (if .url!="" then " ("+ .url +")" else "" end)' "$RAW_JSON"
      echo ""
    done <<< "$statuses"
  } > "$out"
}

write_filtered() {
  local out="$1"
  shift
  local -a allowed=("$@")

  {
    GEN_HEADER
    echo "# $PROJECT_TITLE — View"
    echo ""
    echo "Allowed statuses: ${allowed[*]}"
    echo ""

    local jq_filter='.'
    # Build a jq expression: select(status in allowed)
    local allowed_json
    allowed_json=$(printf '%s\n' "${allowed[@]}" | jq -R . | jq -s .)

    jq -r --argjson allowed "$allowed_json" '.items[] | select(.status as $s | ($allowed | index($s))) | "- [ ] \(.title)" + (if .url!="" then " ("+ .url +")" else "" end)' "$RAW_JSON"
    echo ""
    echo "Project: $PROJECT_URL"
  } > "$out"
}

write_grouped_by_status "$REPO_DIR/ROADMAP.md"
write_filtered "$REPO_DIR/TODAY.md" "In Progress" "Doing"
write_filtered "$REPO_DIR/BACKLOG.md" "Todo" "To do" "Backlog" "Triage"

echo "Wrote: $REPO_DIR/ROADMAP.md"
echo "Wrote: $REPO_DIR/TODAY.md"
echo "Wrote: $REPO_DIR/BACKLOG.md"
