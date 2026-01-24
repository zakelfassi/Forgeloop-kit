#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Sync Ralph Kit skills into agent-specific discovery locations.

Usage:
  ./ralph/bin/sync-skills.sh [--claude] [--codex] [--claude-global] [--codex-global] [--amp] [--all] [--include-project] [--project-prefix <prefix>]

What it does:
  --claude        Create/refresh .claude/skills symlinks in the repo (Claude Code)
  --codex         Create/refresh .codex/skills symlinks in the repo (Codex)
  --claude-global Copy skills into ~/.claude/skills (Claude user dir)
  --codex-global  Copy skills into ~/.codex/skills (Codex user dir)
  --amp           Copy skills into ~/.config/amp/skills (Amp)
  --all           Enable all targets

Notes:
  - Skills are sourced from ralph/skills when vendored, or ./skills when running in this repo.
  - When vendored, repo-root ./skills (project skills) are also linked into .claude/skills and .codex/skills (if present).
  - Use --include-project to also install repo-root ./skills into global agent dirs (namespaced by --project-prefix).
USAGE
}

want_claude=false
want_codex=false
want_claude_global=false
want_codex_global=false
want_amp=false
include_project=false
project_prefix=""

explicit_targets=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --claude)
      want_claude=true
      explicit_targets=true
      shift
      ;;
    --codex)
      want_codex=true
      explicit_targets=true
      shift
      ;;
    --claude-global)
      want_claude_global=true
      explicit_targets=true
      shift
      ;;
    --codex-global)
      want_codex_global=true
      explicit_targets=true
      shift
      ;;
    --amp)
      want_amp=true
      explicit_targets=true
      shift
      ;;
    --all)
      want_claude=true
      want_codex=true
      want_claude_global=true
      want_codex_global=true
      want_amp=true
      explicit_targets=true
      shift
      ;;
    --include-project)
      include_project=true
      shift
      ;;
    --project-prefix)
      project_prefix="${2:-}"
      if [[ -z "$project_prefix" ]]; then
        echo "Error: --project-prefix requires a value" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ "$explicit_targets" != "true" ]]; then
  # Default behavior: keep repo-scoped discovery in sync for both Claude Code and Codex.
  want_claude=true
  want_codex=true
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Resolve repo root for both:
# - vendored:   <repo>/ralph/bin/sync-skills.sh  -> <repo>
# - standalone: <repo>/bin/sync-skills.sh        -> <repo>
if [[ "$script_dir" == */ralph/bin ]]; then
  repo_dir="$(cd "$script_dir/../.." && pwd)"
  ralph_dir="$repo_dir/ralph"
else
  repo_dir="$(cd "$script_dir/.." && pwd)"
  ralph_dir="$repo_dir"
fi

kit_skills_root="$ralph_dir/skills"
project_skills_root="$repo_dir/skills"
repo_name="$(basename "$repo_dir")"

sanitize_prefix_component() {
  # Produce a safe, filesystem-friendly prefix component (ASCII-ish).
  # Keep it simple and portable (macOS default bash + BSD tools).
  local raw="$1"
  local lowered cleaned collapsed trimmed
  lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  cleaned="$(printf '%s' "$lowered" | tr -c 'a-z0-9._-' '-')"
  collapsed="$(printf '%s' "$cleaned" | sed 's/--*/-/g')"
  trimmed="$(printf '%s' "$collapsed" | sed 's/^-//; s/-$//')"
  printf '%s' "$trimmed"
}

if [[ -z "$project_prefix" ]]; then
  default_prefix="$(sanitize_prefix_component "$repo_name")"
  if [[ -z "$default_prefix" ]]; then
    default_prefix="project"
  fi
  project_prefix="${default_prefix}-"
fi

if [[ ! -d "$kit_skills_root" ]]; then
  echo "No skills directory found at: $kit_skills_root" >&2
  exit 1
fi

link_repo_skills=false
if [[ "$repo_dir" != "$ralph_dir" ]] && [[ -d "$project_skills_root" ]]; then
  link_repo_skills=true
fi

validate_project_prefix() {
  local prefix="$1"
  if [[ -z "$prefix" ]]; then
    echo "Error: project prefix is empty" >&2
    exit 2
  fi
  if [[ "$prefix" == *"/"* ]] || [[ "$prefix" == *"\\"* ]]; then
    echo "Error: --project-prefix must not contain path separators" >&2
    exit 2
  fi
  if [[ ! "$prefix" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: --project-prefix must match ^[A-Za-z0-9._-]+$" >&2
    exit 2
  fi
}

repo_relpath_from_root() {
  local abs="$1"
  local prefix="${repo_dir%/}/"
  if [[ "$abs" != "$prefix"* ]]; then
    echo "Error: expected path under repo root: $abs" >&2
    return 1
  fi
  printf '%s' "${abs:${#prefix}}"
}

ensure_dir_writable() {
  # `test -w` isn't reliable under sandboxing; probe with an actual write.
  local dir="$1"
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 1
  fi

  local probe="$dir/.write-probe.$$.$RANDOM"
  if ( : > "$probe" ) 2>/dev/null; then
    rm -f "$probe" 2>/dev/null || true
    return 0
  fi
  return 1
}

sync_claude() {
  local dst_dir="$repo_dir/.claude/skills"
  mkdir -p "$dst_dir"

  # Remove broken symlinks (portable).
  for p in "$dst_dir"/*; do
    [[ -L "$p" && ! -e "$p" ]] && rm -f "$p" || true
  done

  # Link kit skills as ralph-<name> to avoid collisions with project skills.
  while IFS= read -r -d '' skill_md; do
    local skill_dir skill_name rel target link_name
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"

    rel="$(repo_relpath_from_root "$skill_dir")"
    target="../../$rel"
    link_name="ralph-$skill_name"

    ln -snf "$target" "$dst_dir/$link_name"
    echo "claude: linked $link_name -> $target"
  done < <(find "$kit_skills_root" -type f -name SKILL.md -print0)

  if [[ "$link_repo_skills" == "true" ]]; then
    while IFS= read -r -d '' skill_md; do
      local skill_dir skill_name rel target link_name
      skill_dir="$(dirname "$skill_md")"
      skill_name="$(basename "$skill_dir")"

      rel="$(repo_relpath_from_root "$skill_dir")"
      target="../../$rel"
      link_name="$skill_name"

      ln -snf "$target" "$dst_dir/$link_name"
      echo "claude: linked $link_name -> $target"
    done < <(find "$project_skills_root" -type f -name SKILL.md -print0)
  fi
}

sync_codex_repo() {
  local dst_dir="$repo_dir/.codex/skills"
  if ! ensure_dir_writable "$dst_dir"; then
    echo "codex: skip repo mirror (not writable): $dst_dir" >&2
    echo "      Tip: run sync-skills outside a sandbox, or commit .codex/skills once and update it manually." >&2
    return 0
  fi

  for p in "$dst_dir"/*; do
    [[ -L "$p" && ! -e "$p" ]] && rm -f "$p" || true
  done

  while IFS= read -r -d '' skill_md; do
    local skill_dir skill_name rel target link_name
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"

    rel="$(repo_relpath_from_root "$skill_dir")"
    target="../../$rel"
    link_name="ralph-$skill_name"

    ln -snf "$target" "$dst_dir/$link_name"
    echo "codex: linked $link_name -> $target"
  done < <(find "$kit_skills_root" -type f -name SKILL.md -print0)

  if [[ "$link_repo_skills" == "true" ]]; then
    while IFS= read -r -d '' skill_md; do
      local skill_dir skill_name rel target link_name
      skill_dir="$(dirname "$skill_md")"
      skill_name="$(basename "$skill_dir")"

      rel="$(repo_relpath_from_root "$skill_dir")"
      target="../../$rel"
      link_name="$skill_name"

      ln -snf "$target" "$dst_dir/$link_name"
      echo "codex: linked $link_name -> $target"
    done < <(find "$project_skills_root" -type f -name SKILL.md -print0)
  fi
}

sync_copy_tree() {
  local src_dir="$1"
  local dest_dir="$2"
  mkdir -p "$dest_dir"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src_dir/" "$dest_dir/"
  else
    rm -rf "$dest_dir" 2>/dev/null || true
    mkdir -p "$dest_dir"
    # Copy dotfiles too; match rsync behavior as closely as possible.
    cp -R "$src_dir/." "$dest_dir/" 2>/dev/null || true
  fi
}

sync_global_dir() {
  local agent_name="$1"
  local agent_dir="$2"

  local parent_dir
  parent_dir="$(dirname "$agent_dir")"
  if [[ ! -d "$parent_dir" ]]; then
    echo "skip: $agent_name not detected (missing $parent_dir)"
    return 0
  fi

  if ! ensure_dir_writable "$agent_dir"; then
    echo "skip: $agent_name global skills dir not writable: $agent_dir" >&2
    return 0
  fi

  while IFS= read -r -d '' skill_md; do
    local skill_dir skill_name dest_skill_dir
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    dest_skill_dir="$agent_dir/ralph-$skill_name"

    sync_copy_tree "$skill_dir" "$dest_skill_dir"
    echo "$agent_name: wrote $dest_skill_dir (from $skill_dir)"
  done < <(find "$kit_skills_root" -type f -name SKILL.md -print0)

  if [[ "$include_project" == "true" && "$link_repo_skills" == "true" ]]; then
    validate_project_prefix "$project_prefix"
    while IFS= read -r -d '' skill_md; do
      local skill_dir skill_name dest_skill_dir
      skill_dir="$(dirname "$skill_md")"
      skill_name="$(basename "$skill_dir")"
      dest_skill_dir="$agent_dir/${project_prefix}${skill_name}"

      sync_copy_tree "$skill_dir" "$dest_skill_dir"
      echo "$agent_name: wrote $dest_skill_dir (from $skill_dir)"
    done < <(find "$project_skills_root" -type f -name SKILL.md -print0)
  fi
}

if [[ "$want_claude" == "true" ]]; then
  sync_claude
fi

if [[ "$want_codex" == "true" ]]; then
  sync_codex_repo
fi

if [[ "$want_claude_global" == "true" ]]; then
  sync_global_dir "claude" "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
fi

if [[ "$want_codex_global" == "true" ]]; then
  sync_global_dir "codex" "${CODEX_SKILLS_DIR:-$HOME/.codex/skills}"
fi

if [[ "$want_amp" == "true" ]]; then
  sync_global_dir "amp" "${AMP_SKILLS_DIR:-$HOME/.config/amp/skills}"
fi
