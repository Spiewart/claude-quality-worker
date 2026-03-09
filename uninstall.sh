#!/usr/bin/env bash
# =============================================================================
# claude-quality-worker — Uninstall from a target repo
#
# Usage:
#   ./uninstall.sh ~/path/to/repo [--remove-files]
# =============================================================================
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <repo-path> [--remove-files]"
    echo ""
    echo "Options:"
    echo "  --remove-files    Also remove .claude/quality-worker/ directory"
    echo "                    (default: keeps files, only removes launchd agent)"
    exit 0
fi

REPO_DIR="$(cd "$1" && pwd)"
REMOVE_FILES=false
[[ "${2:-}" == "--remove-files" ]] && REMOVE_FILES=true

REPO_NAME="$(basename "$REPO_DIR")"
LABEL="com.claude.quality-worker.${REPO_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
WORKER_DIR="$REPO_DIR/.claude/quality-worker"

echo "=========================================="
echo "claude-quality-worker — Uninstalling"
echo "=========================================="
echo "Repo:  $REPO_DIR"
echo "Label: $LABEL"
echo ""

# ---------------------------------------------------------------------------
# Check for preserved worktrees with unsaved work
# ---------------------------------------------------------------------------
if [[ -d "$WORKER_DIR/worktrees" ]]; then
    ACTIVE_WORKTREES=$(find "$WORKER_DIR/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
    if [[ -n "$ACTIVE_WORKTREES" ]]; then
        echo "⚠ Found active worktrees:"
        echo "$ACTIVE_WORKTREES" | while read -r wt; do
            echo "  - $wt"
            if git -C "$wt" status --porcelain 2>/dev/null | grep -q .; then
                echo "    ↳ HAS UNCOMMITTED CHANGES"
            fi
        done
        echo ""
        echo "These worktrees may contain unsaved work."
        read -rp "Continue with uninstall? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Unload launchd agent
# ---------------------------------------------------------------------------
if [[ -f "$PLIST_PATH" ]]; then
    echo "Unloading launchd agent..."
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "✓ Removed: $PLIST_PATH"
else
    echo "No launchd plist found (already removed?)"
fi

# ---------------------------------------------------------------------------
# Remove files if requested
# ---------------------------------------------------------------------------
if [[ "$REMOVE_FILES" == true ]]; then
    if [[ -d "$WORKER_DIR" ]]; then
        echo "Removing worker directory..."
        rm -rf "$WORKER_DIR"
        echo "✓ Removed: $WORKER_DIR"
    fi
else
    echo ""
    echo "Worker files preserved at: $WORKER_DIR"
    echo "  (use --remove-files to delete them)"
fi

echo ""
echo "✓ Uninstall complete for $REPO_NAME"
