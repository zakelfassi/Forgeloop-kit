#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Ralph framework installer.

Usage:
  ./install.sh [target_repo_dir] [--force] [--wrapper] [--skills]

Examples:
  # From the ralph-kit repo:
  ./install.sh /path/to/target-repo --wrapper --skills

  # From within a target repo where this kit is vendored at ./ralph:
  ./ralph/install.sh --wrapper

Flags:
  --force     Overwrite existing files
  --wrapper   Create ./ralph.sh convenience wrapper
  --skills    Install skills to user agent directories (~/.claude/skills, ~/.codex/skills, etc.)
USAGE
}

SRC_KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_KIT_NAME="$(basename "$SRC_KIT_DIR")"

FORCE="false"
WRAPPER="false"
SKILLS="false"

# Default target:
# - If this installer lives in a folder named "ralph", assume it's vendored into a repo at ./ralph and
#   default to the parent directory (repo root).
# - Otherwise (e.g., running from the standalone ralph-kit repo), require an explicit target path.
TARGET_REPO_DIR=""
if [ "$SRC_KIT_NAME" = "ralph" ]; then
    TARGET_REPO_DIR="$(cd "$SRC_KIT_DIR/.." && pwd)"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --force)
            FORCE="true"
            shift
            ;;
        --wrapper)
            WRAPPER="true"
            shift
            ;;
        --skills)
            SKILLS="true"
            shift
            ;;
        *)
            TARGET_REPO_DIR="$(cd "$1" 2>/dev/null && pwd || true)"
            if [ -z "$TARGET_REPO_DIR" ]; then
                echo "Error: target repo dir not found: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$TARGET_REPO_DIR" ]; then
    echo "Error: target repo dir required." >&2
    usage
    exit 1
fi

DEST_KIT_DIR="$TARGET_REPO_DIR/ralph"

copy_kit() {
    mkdir -p "$DEST_KIT_DIR"

    if [ "$SRC_KIT_DIR" = "$DEST_KIT_DIR" ]; then
        return 0
    fi

    if command -v rsync >/dev/null 2>&1; then
        rsync -a \
            --exclude '.git' \
            --exclude '.DS_Store' \
            "$SRC_KIT_DIR/" "$DEST_KIT_DIR/"
    else
        # tar fallback (preserves file modes; excludes .git)
        (cd "$SRC_KIT_DIR" && tar --exclude='.git' --exclude='.DS_Store' -cf - .) | (cd "$DEST_KIT_DIR" && tar -xf -)
    fi
}

install_file() {
    local src="$1"
    local dest="$2"

    if [ -e "$dest" ] && [ "$FORCE" != "true" ]; then
        echo "skip: $dest (exists)"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "write: $dest"
}

ensure_gitignore() {
    local gitignore="$TARGET_REPO_DIR/.gitignore"
    local line=".ralph/"

    if [ ! -f "$gitignore" ]; then
        echo "$line" > "$gitignore"
        echo "write: $gitignore"
        return 0
    fi

    if grep -qF "$line" "$gitignore" 2>/dev/null; then
        return 0
    fi

    echo "" >> "$gitignore"
    echo "$line" >> "$gitignore"
    echo "update: $gitignore (+$line)"
}

install_skills() {
    local skills_src="$SRC_KIT_DIR/skills"

    if [ ! -d "$skills_src" ]; then
        echo "skip: skills directory not found in kit"
        return 0
    fi

    # Agent directories to install skills into
    local agent_dirs=(
        "$HOME/.claude/skills"
        "$HOME/.codex/skills"
        "$HOME/.config/amp/skills"
    )

    for agent_dir in "${agent_dirs[@]}"; do
        # Skip if parent dir doesn't exist (agent not installed)
        local parent_dir
        parent_dir="$(dirname "$agent_dir")"
        if [ ! -d "$parent_dir" ]; then
            continue
        fi

        # Some sandboxed environments block writes to agent config dirs. Probe with an actual write.
        if ! mkdir -p "$agent_dir" 2>/dev/null; then
            echo "skip: cannot write $agent_dir"
            continue
        fi
        local probe_file
        probe_file="$agent_dir/.write-probe.$$"
        if ! ( : > "$probe_file" ) 2>/dev/null; then
            echo "skip: cannot write $agent_dir"
            continue
        fi
        rm -f "$probe_file" 2>/dev/null || true

        # Copy each skill (supports typed layout: skills/<type>/<name>/SKILL.md)
        while IFS= read -r -d '' skill_md; do
            local skill_dir skill_name dest_skill_dir
            skill_dir="$(dirname "$skill_md")"
            skill_name="$(basename "$skill_dir")"
            dest_skill_dir="$agent_dir/ralph-$skill_name"

            if [ -e "$dest_skill_dir" ] && [ "$FORCE" != "true" ]; then
                echo "skip: $dest_skill_dir (exists)"
                continue
            fi

            mkdir -p "$dest_skill_dir"
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --delete "$skill_dir/" "$dest_skill_dir/"
            else
                rm -rf "$dest_skill_dir" 2>/dev/null || true
                mkdir -p "$dest_skill_dir"
                # Copy dotfiles too; match rsync behavior as closely as possible.
                cp -R "$skill_dir/." "$dest_skill_dir/" 2>/dev/null || true
            fi
            echo "write: $dest_skill_dir (from $skill_dir)"
        done < <(find "$skills_src" -type f -name SKILL.md -print0)
    done
}

install_wrapper() {
    local wrapper_path="$TARGET_REPO_DIR/ralph.sh"

    if [ -e "$wrapper_path" ] && [ "$FORCE" != "true" ]; then
        echo "skip: $wrapper_path (exists)"
        return 0
    fi

    cat > "$wrapper_path" <<'RALPH_WRAPPER_SH'
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./ralph.sh plan [max_iters]
  ./ralph.sh plan-work "scope" [max_iters]
  ./ralph.sh build [max_iters]
  ./ralph.sh tasks [max_iters]
  ./ralph.sh review
  ./ralph.sh sync-skills [--claude] [--codex] [--claude-global] [--codex-global] [--amp] [--all] [--include-project] [--project-prefix <prefix>]
  ./ralph.sh daemon [interval_seconds]
  ./ralph.sh ask "category" "question"
  ./ralph.sh notify "emoji" "title" "message"
  ./ralph.sh ingest --report <file> [--mode request|plan-work]
  ./ralph.sh kickoff "<brief>" [--project <name>] [--seed <path-or-url>] [--notes <text>] [--out <path>]
USAGE
}

cmd="${1:-}"
case "$cmd" in
  plan)
    exec "$REPO_DIR/ralph/bin/loop.sh" plan "${2:-0}"
    ;;
  plan-work)
    shift
    exec "$REPO_DIR/ralph/bin/loop.sh" plan-work "$@"
    ;;
  build)
    exec "$REPO_DIR/ralph/bin/loop.sh" "${2:-10}"
    ;;
  review)
    exec "$REPO_DIR/ralph/bin/loop.sh" review
    ;;
  tasks)
    exec "$REPO_DIR/ralph/bin/loop-tasks.sh" "${2:-10}"
    ;;
  sync-skills)
    shift
    exec "$REPO_DIR/ralph/bin/sync-skills.sh" "$@"
    ;;
  daemon)
    exec "$REPO_DIR/ralph/bin/ralph-daemon.sh" "${2:-300}"
    ;;
  ask)
    shift
    exec "$REPO_DIR/ralph/bin/ask.sh" "$@"
    ;;
  notify)
    shift
    exec "$REPO_DIR/ralph/bin/notify.sh" "$@"
    ;;
  kickoff)
    shift
    exec "$REPO_DIR/ralph/bin/kickoff.sh" "$@"
    ;;
  ingest)
    shift
    exec "$REPO_DIR/ralph/bin/ingest-report.sh" "$@"
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
RALPH_WRAPPER_SH

    chmod +x "$wrapper_path"
    echo "write: $wrapper_path"
}

main() {
    echo "Installing Ralph framework into: $TARGET_REPO_DIR"

    copy_kit

    # Ensure scripts are executable
    chmod +x "$DEST_KIT_DIR/bin/"*.sh "$DEST_KIT_DIR/config.sh" "$DEST_KIT_DIR/install.sh" 2>/dev/null || true

    # Root coordination files
    install_file "$DEST_KIT_DIR/templates/AGENTS.md" "$TARGET_REPO_DIR/AGENTS.md"
    install_file "$DEST_KIT_DIR/templates/CLAUDE.md" "$TARGET_REPO_DIR/CLAUDE.md"
    install_file "$DEST_KIT_DIR/templates/PROMPT_plan.md" "$TARGET_REPO_DIR/PROMPT_plan.md"
    install_file "$DEST_KIT_DIR/templates/PROMPT_plan_work.md" "$TARGET_REPO_DIR/PROMPT_plan_work.md"
    install_file "$DEST_KIT_DIR/templates/PROMPT_build.md" "$TARGET_REPO_DIR/PROMPT_build.md"
    install_file "$DEST_KIT_DIR/templates/IMPLEMENTATION_PLAN.md" "$TARGET_REPO_DIR/IMPLEMENTATION_PLAN.md"
    install_file "$DEST_KIT_DIR/templates/REQUESTS.md" "$TARGET_REPO_DIR/REQUESTS.md"
    install_file "$DEST_KIT_DIR/templates/QUESTIONS.md" "$TARGET_REPO_DIR/QUESTIONS.md"
    install_file "$DEST_KIT_DIR/templates/STATUS.md" "$TARGET_REPO_DIR/STATUS.md"
    install_file "$DEST_KIT_DIR/templates/CHANGELOG.md" "$TARGET_REPO_DIR/CHANGELOG.md"

    # Specs + docs folders
    install_file "$DEST_KIT_DIR/templates/specs/README.md" "$TARGET_REPO_DIR/specs/README.md"
    install_file "$DEST_KIT_DIR/templates/specs/feature_template.md" "$TARGET_REPO_DIR/specs/feature_template.md"
    install_file "$DEST_KIT_DIR/templates/docs/README.md" "$TARGET_REPO_DIR/docs/README.md"

    ensure_gitignore

    if [ "$WRAPPER" = "true" ]; then
        install_wrapper
    fi

    if [ "$SKILLS" = "true" ]; then
        install_skills
    fi

    echo "Done."
    echo "Next (in the target repo):"
    echo "  cd \"$TARGET_REPO_DIR\""
    echo "  ./ralph/bin/loop.sh plan 1"
    echo "  ./ralph/bin/loop.sh 5"
}

main
