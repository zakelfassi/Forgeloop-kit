#!/bin/bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Forgeloop framework installer.

Usage:
  ./install.sh [target_repo_dir] [--force] [--wrapper] [--skills]

Examples:
  # From the forgeloop repo:
  ./install.sh /path/to/target-repo --wrapper --skills

  # From within a target repo where this kit is vendored at ./forgeloop:
  ./forgeloop/install.sh --wrapper

Flags:
  --force         Overwrite existing files
  --wrapper       Create ./forgeloop.sh convenience wrapper
  --skills        Install skills to user agent directories (~/.claude/skills, ~/.codex/skills, etc.)
  --interactive   Force interactive prompts for conflicts (even in non-TTY)
  --batch         Skip conflicts silently (no prompts, like CI)
USAGE
}

SRC_KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_KIT_NAME="$(basename "$SRC_KIT_DIR")"

FORCE="false"
WRAPPER="false"
SKILLS="false"
INTERACTIVE="auto"  # auto, true, false

# Default target:
# - If this installer lives in a folder named "forgeloop", assume it's vendored into a repo at ./forgeloop and
#   default to the parent directory (repo root).
# - Otherwise (e.g., running from the standalone forgeloop repo), require an explicit target path.
TARGET_REPO_DIR=""
if [ "$SRC_KIT_NAME" = "forgeloop" ]; then
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
        --interactive|-i)
            INTERACTIVE="true"
            shift
            ;;
        --batch|-b)
            INTERACTIVE="false"
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

DEST_KIT_DIR="$TARGET_REPO_DIR/forgeloop"

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

# Check if running interactively
is_interactive() {
    case "$INTERACTIVE" in
        true) return 0 ;;
        false) return 1 ;;
        auto) [[ -t 0 && -t 1 ]] ;;
    esac
}

# Prompt user for conflict resolution
# Returns: skip, overwrite, merge
prompt_conflict() {
    local dest="$1"
    local src="$2"

    if ! is_interactive; then
        echo "skip"
        return
    fi

    while true; do
        echo ""
        echo "  $dest already exists. What would you like to do?"
        echo "    [s]kip      - Keep existing file (default)"
        echo "    [o]verwrite - Replace with template"
        echo "    [m]erge     - Append template below separator"
        echo "    [d]iff      - Show differences, then ask again"
        printf "  > "

        read -r choice </dev/tty
        choice="${choice:-s}"

        case "$choice" in
            s|S|skip)
                echo "skip"
                return
                ;;
            o|O|overwrite)
                echo "overwrite"
                return
                ;;
            m|M|merge)
                echo "merge"
                return
                ;;
            d|D|diff)
                echo ""
                if command -v diff >/dev/null 2>&1; then
                    diff -u "$dest" "$src" | head -50 || true
                else
                    echo "(diff not available)"
                fi
                # Loop continues to ask again
                ;;
            *)
                echo "  Invalid choice. Please enter s, o, m, or d."
                ;;
        esac
    done
}

merge_file() {
    local src="$1"
    local dest="$2"
    local separator

    separator="
# ─────────────────────────────────────────────────────────────
# Forgeloop Template (merged $(date +%Y-%m-%d))
# ─────────────────────────────────────────────────────────────
"

    # Append separator and template content to existing file
    {
        echo "$separator"
        cat "$src"
    } >> "$dest"
}

install_file() {
    local src="$1"
    local dest="$2"

    if [ -e "$dest" ]; then
        if [ "$FORCE" = "true" ]; then
            # Force mode: overwrite silently
            mkdir -p "$(dirname "$dest")"
            cp "$src" "$dest"
            echo "write: $dest (overwritten)"
            return 0
        fi

        local action
        action="$(prompt_conflict "$dest" "$src")"

        case "$action" in
            skip)
                echo "skip: $dest (exists)"
                return 0
                ;;
            overwrite)
                mkdir -p "$(dirname "$dest")"
                cp "$src" "$dest"
                echo "write: $dest (overwritten)"
                return 0
                ;;
            merge)
                merge_file "$src" "$dest"
                echo "merge: $dest (template appended)"
                return 0
                ;;
        esac
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "write: $dest"
}

ensure_gitignore() {
    local gitignore="$TARGET_REPO_DIR/.gitignore"
    local line=".forgeloop/"

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
            dest_skill_dir="$agent_dir/forgeloop-$skill_name"

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

detect_and_configure_ci_gate() {
    # Source the core library to use detection function
    # shellcheck disable=SC1091
    source "$DEST_KIT_DIR/lib/core.sh" 2>/dev/null || return 0

    ci_gate__escape_for_double_quotes() {
        local s="$1"
        s=${s//\\/\\\\}
        s=${s//\"/\\\"}
        s=${s//\$/\\\$}
        s=${s//\`/\\\`}
        s=${s//$'\n'/ }
        s=${s//$'\r'/ }
        echo "$s"
    }

    ci_gate__escape_for_sed_replacement() {
        local s="$1"
        s=${s//\\/\\\\}
        s=${s//&/\\&}
        s=${s//|/\\|}
        s=${s//$'\n'/ }
        s=${s//$'\r'/ }
        echo "$s"
    }

    local detected_gate_cmd
    detected_gate_cmd=$(forgeloop_core__detect_ci_gate_cmd "$TARGET_REPO_DIR")

    local config_file="$DEST_KIT_DIR/config.sh"

    if [[ -n "$detected_gate_cmd" ]]; then
        echo "Detected CI gate command: $detected_gate_cmd"
        local escaped_gate_cmd
        escaped_gate_cmd=$(ci_gate__escape_for_double_quotes "$detected_gate_cmd")
        local sed_gate_cmd
        sed_gate_cmd=$(ci_gate__escape_for_sed_replacement "$escaped_gate_cmd")
        # Append to config.sh if not already set
        if ! grep -q "^export FORGELOOP_CI_GATE_CMD=" "$config_file" 2>/dev/null || \
           grep -q "^export FORGELOOP_CI_GATE_CMD=\"\${FORGELOOP_CI_GATE_CMD:-}\"$" "$config_file" 2>/dev/null; then
            # Replace the empty default with the detected command
            if grep -q "^export FORGELOOP_CI_GATE_CMD=" "$config_file" 2>/dev/null; then
                sed -i.bak "s|^export FORGELOOP_CI_GATE_CMD=.*|export FORGELOOP_CI_GATE_CMD=\"\${FORGELOOP_CI_GATE_CMD:-$sed_gate_cmd}\"|" "$config_file"
                rm -f "$config_file.bak"
            else
                echo "" >> "$config_file"
                echo "# Auto-detected CI gate command" >> "$config_file"
                echo "export FORGELOOP_CI_GATE_CMD=\"\${FORGELOOP_CI_GATE_CMD:-$escaped_gate_cmd}\"" >> "$config_file"
            fi
            echo "write: CI gate configured in $config_file"
        fi
    else
        # Prompt user if interactive and no command detected
        if is_interactive; then
            echo ""
            echo "Could not auto-detect CI gate command for this project."
            echo "What command should run before pushing to main? (leave empty to skip)"
            printf "  > "
            read -r user_gate_cmd </dev/tty
            if [[ -n "$user_gate_cmd" ]]; then
                local escaped_user_cmd
                escaped_user_cmd=$(ci_gate__escape_for_double_quotes "$user_gate_cmd")
                local sed_user_cmd
                sed_user_cmd=$(ci_gate__escape_for_sed_replacement "$escaped_user_cmd")
                if grep -q "^export FORGELOOP_CI_GATE_CMD=" "$config_file" 2>/dev/null; then
                    sed -i.bak "s|^export FORGELOOP_CI_GATE_CMD=.*|export FORGELOOP_CI_GATE_CMD=\"\${FORGELOOP_CI_GATE_CMD:-$sed_user_cmd}\"|" "$config_file"
                    rm -f "$config_file.bak"
                else
                    echo "" >> "$config_file"
                    echo "# User-specified CI gate command" >> "$config_file"
                    echo "export FORGELOOP_CI_GATE_CMD=\"\${FORGELOOP_CI_GATE_CMD:-$escaped_user_cmd}\"" >> "$config_file"
                fi
                echo "write: CI gate configured in $config_file"
            fi
        fi
    fi
}

install_wrapper() {
    local wrapper_path="$TARGET_REPO_DIR/forgeloop.sh"

    if [ -e "$wrapper_path" ] && [ "$FORCE" != "true" ]; then
        echo "skip: $wrapper_path (exists)"
        return 0
    fi

    cat > "$wrapper_path" <<'FORGELOOP_WRAPPER_SH'
#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./forgeloop.sh plan [max_iters] [--lite|--full] [--watch|--infinite]
  ./forgeloop.sh plan-work "scope" [max_iters] [--watch|--infinite]
  ./forgeloop.sh build [max_iters] [--lite|--full] [--watch|--infinite]
  ./forgeloop.sh tasks [max_iters]
  ./forgeloop.sh review
  ./forgeloop.sh sync-skills [--claude] [--codex] [--claude-global] [--codex-global] [--amp] [--all] [--include-project] [--project-prefix <prefix>]
  ./forgeloop.sh daemon [interval_seconds]
  ./forgeloop.sh ask "category" "question"
  ./forgeloop.sh notify "emoji" "title" "message"
  ./forgeloop.sh ingest --report <file> [--mode request|plan-work]
  ./forgeloop.sh ingest-logs (--file <path> | --cmd "<command>" | --latest) [--tail <lines>] [--mode request|plan-work]
  ./forgeloop.sh kickoff "<brief>" [--project <name>] [--seed <path-or-url>] [--notes <text>] [--out <path>]
  ./forgeloop.sh session-start     # Load knowledge context
  ./forgeloop.sh session-end       # Capture session knowledge

Modes:
  --lite    Use AGENTS-lite.md for simple one-shot tasks
  --full    Force full AGENTS.md mode (default)
USAGE
}

# Parse global flags
FORGELOOP_LITE=false
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lite) FORGELOOP_LITE=true; shift ;;
    --full) FORGELOOP_LITE=false; shift ;;
    --watch|--infinite) args+=("$1"); shift ;;
    --) shift; while [[ $# -gt 0 ]]; do args+=("$1"); shift; done; break ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]:-}"

export FORGELOOP_LITE

cmd="${1:-}"
case "$cmd" in
  plan)
    shift
    max="${1:-}"
    if [[ "$max" =~ ^[0-9]+$ ]]; then
      max_iters="$max"
      shift
    else
      max_iters="1"
    fi
    exec "$REPO_DIR/forgeloop/bin/loop.sh" plan "$max_iters" "$@"
    ;;
  plan-work)
    shift
    exec "$REPO_DIR/forgeloop/bin/loop.sh" plan-work "$@"
    ;;
  build)
    shift
    max="${1:-}"
    if [[ "$max" =~ ^[0-9]+$ ]]; then
      max_iters="$max"
      shift
    else
      max_iters="10"
    fi
    exec "$REPO_DIR/forgeloop/bin/loop.sh" "$max_iters" "$@"
    ;;
  review)
    exec "$REPO_DIR/forgeloop/bin/loop.sh" review
    ;;
  tasks)
    exec "$REPO_DIR/forgeloop/bin/loop-tasks.sh" "${2:-10}"
    ;;
  sync-skills)
    shift
    exec "$REPO_DIR/forgeloop/bin/sync-skills.sh" "$@"
    ;;
  daemon)
    exec "$REPO_DIR/forgeloop/bin/forgeloop-daemon.sh" "${2:-300}"
    ;;
  ask)
    shift
    exec "$REPO_DIR/forgeloop/bin/ask.sh" "$@"
    ;;
  notify)
    shift
    exec "$REPO_DIR/forgeloop/bin/notify.sh" "$@"
    ;;
  kickoff)
    shift
    exec "$REPO_DIR/forgeloop/bin/kickoff.sh" "$@"
    ;;
  ingest)
    shift
    exec "$REPO_DIR/forgeloop/bin/ingest-report.sh" "$@"
    ;;
  ingest-logs)
    shift
    exec "$REPO_DIR/forgeloop/bin/ingest-logs.sh" "$@"
    ;;
  session-start)
    exec "$REPO_DIR/forgeloop/bin/session-start.sh"
    ;;
  session-end)
    shift
    exec "$REPO_DIR/forgeloop/bin/session-end.sh" "$@"
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
FORGELOOP_WRAPPER_SH

    chmod +x "$wrapper_path"
    echo "write: $wrapper_path"
}

main() {
    echo "Installing Forgeloop framework into: $TARGET_REPO_DIR"

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

    # Knowledge persistence system
    install_file "$DEST_KIT_DIR/templates/system/knowledge/_index.md" "$TARGET_REPO_DIR/system/knowledge/_index.md"
    install_file "$DEST_KIT_DIR/templates/system/knowledge/decisions.md" "$TARGET_REPO_DIR/system/knowledge/decisions.md"
    install_file "$DEST_KIT_DIR/templates/system/knowledge/patterns.md" "$TARGET_REPO_DIR/system/knowledge/patterns.md"
    install_file "$DEST_KIT_DIR/templates/system/knowledge/preferences.md" "$TARGET_REPO_DIR/system/knowledge/preferences.md"
    install_file "$DEST_KIT_DIR/templates/system/knowledge/insights.md" "$TARGET_REPO_DIR/system/knowledge/insights.md"
    install_file "$DEST_KIT_DIR/templates/system/knowledge/archive.md" "$TARGET_REPO_DIR/system/knowledge/archive.md"

    # Domain expert system
    install_file "$DEST_KIT_DIR/templates/system/experts/_index.md" "$TARGET_REPO_DIR/system/experts/_index.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/architecture.md" "$TARGET_REPO_DIR/system/experts/architecture.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/security.md" "$TARGET_REPO_DIR/system/experts/security.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/testing.md" "$TARGET_REPO_DIR/system/experts/testing.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/implementation.md" "$TARGET_REPO_DIR/system/experts/implementation.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/devops.md" "$TARGET_REPO_DIR/system/experts/devops.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/design.md" "$TARGET_REPO_DIR/system/experts/design.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/documentation.md" "$TARGET_REPO_DIR/system/experts/documentation.md"
    install_file "$DEST_KIT_DIR/templates/system/experts/product.md" "$TARGET_REPO_DIR/system/experts/product.md"

    # Lite mode agents file
    install_file "$DEST_KIT_DIR/templates/AGENTS-lite.md" "$TARGET_REPO_DIR/AGENTS-lite.md"

    ensure_gitignore

    if [ "$WRAPPER" = "true" ]; then
        install_wrapper
    fi

    if [ "$SKILLS" = "true" ]; then
        install_skills
    fi

    # Auto-detect CI gate command and append to config if found
    detect_and_configure_ci_gate

    echo "Done."
    echo "Next (in the target repo):"
    echo "  cd \"$TARGET_REPO_DIR\""
    echo "  ./forgeloop/bin/loop.sh plan 1"
    echo "  ./forgeloop/bin/loop.sh 5"
}

main
