#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Ralph framework installer.

Usage:
  ./install.sh [target_repo_dir] [--force] [--wrapper]

Examples:
  # From the ralph-kit repo:
  ./install.sh /path/to/target-repo --wrapper

  # From within a target repo where this kit is vendored at ./ralph:
  ./ralph/install.sh --wrapper

Flags:
  --force     Overwrite existing files
  --wrapper   Create ./ralph.sh convenience wrapper
USAGE
}

SRC_KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_KIT_NAME="$(basename "$SRC_KIT_DIR")"

FORCE="false"
WRAPPER="false"

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
  ./ralph.sh review
  ./ralph.sh daemon [interval_seconds]
  ./ralph.sh ask "category" "question"
  ./ralph.sh notify "emoji" "title" "message"
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

    echo "Done."
    echo "Next (in the target repo):"
    echo "  cd \"$TARGET_REPO_DIR\""
    echo "  ./ralph/bin/loop.sh plan 1"
    echo "  ./ralph/bin/loop.sh 5"
}

main
