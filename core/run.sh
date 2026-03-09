#!/usr/bin/env bash
# =============================================================================
# claude-quality-worker — Automated code quality enforcer
#
# Reviews code quality across three domains (lint, types, docs) in an
# isolated git worktree. Tracks review progress via state.json so daily
# runs only process files changed since the last review.
#
# Safe to run while another session is active — uses worktree isolation.
#
# Safety guarantees:
#   - Lock file prevents concurrent runs on the same repo
#   - Never stashes anything (stashes are global — causes cross-branch confusion)
#   - Never force-removes worktrees with uncommitted/unpushed work
#   - Preserves worktree + branch on any failure for manual recovery
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo directory from script location
# ---------------------------------------------------------------------------
# This script lives at <repo>/.claude/quality-worker/run.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source state management functions
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

# Source per-repo config
CONFIG_FILE="$SCRIPT_DIR/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Defaults (overridable via config.sh)
VENV_PATH="${VENV_PATH:-}"
QUALITY_BRANCH_PREFIX="${QUALITY_BRANCH_PREFIX:-quality}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LINT_COMMAND="${LINT_COMMAND:-}"
LINT_FIX_COMMAND="${LINT_FIX_COMMAND:-}"
TYPECHECK_COMMAND="${TYPECHECK_COMMAND:-}"
TEST_COMMAND="${TEST_COMMAND:-}"
SOURCE_DIRS="${SOURCE_DIRS:-src/}"
DOC_FILES="${DOC_FILES:-}"
DEFAULT_BATCH_SIZE="${DEFAULT_BATCH_SIZE:-15}"

# Derived paths
LOG_DIR="$SCRIPT_DIR/logs"
WORKTREE_BASE="$SCRIPT_DIR/worktrees"
LOCK_FILE="$SCRIPT_DIR/.lock"
STATE_FILE="$SCRIPT_DIR/state.json"
DATE=$(date +%Y-%m-%d)
RUN_ID="${DATE}-$(date +%H%M%S)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DOMAIN=""
BASELINE_MODE=false
BATCH_SIZE="$DEFAULT_BATCH_SIZE"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            DOMAIN="$2"
            if [[ "$DOMAIN" != "lint" && "$DOMAIN" != "types" && "$DOMAIN" != "docs" ]]; then
                echo "ERROR: --domain must be lint, types, or docs (got: $DOMAIN)"
                exit 1
            fi
            shift 2
            ;;
        --baseline)
            BASELINE_MODE=true
            shift
            ;;
        --batch-size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --domain DOMAIN    Target domain: lint, types, or docs"
            echo "                     (default: auto-rotate by oldest last_run_date)"
            echo "  --baseline         Force comprehensive review (reset baseline)"
            echo "  --batch-size N     Max files per baseline batch (default: $DEFAULT_BATCH_SIZE)"
            echo "  --dry-run          Show scope without running Claude"
            echo ""
            echo "Repo: $REPO_DIR"
            echo "Config: $CONFIG_FILE"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

# Homebrew paths (needed since launchd doesn't source shell profiles)
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

mkdir -p "$LOG_DIR" "$WORKTREE_BASE"

# Rotate logs older than retention period
find "$LOG_DIR" -name "*.log" -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true

LOG_FILE="$LOG_DIR/${RUN_ID}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

REPO_NAME="$(basename "$REPO_DIR")"

# ---------------------------------------------------------------------------
# Initialize state file
# ---------------------------------------------------------------------------
state_ensure_exists

# ---------------------------------------------------------------------------
# Domain selection (auto-rotate if not specified)
# ---------------------------------------------------------------------------
if [[ -z "$DOMAIN" ]]; then
    DOMAIN=$(state_pick_next_domain)
    echo "Auto-selected domain: $DOMAIN (oldest last_run_date)"
fi

BRANCH_NAME="${QUALITY_BRANCH_PREFIX}/${DOMAIN}/${DATE}"
WORKTREE_DIR="$WORKTREE_BASE/${DOMAIN}-${DATE}"

echo "=========================================="
echo "Quality Worker — $REPO_NAME — $DOMAIN — $RUN_ID"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Repo: $REPO_DIR"
echo "Domain: $DOMAIN"
echo "Mode: $(if [[ "$BASELINE_MODE" == true ]]; then echo "baseline (forced)"; else echo "auto-detect"; fi)"
echo "=========================================="

# ---------------------------------------------------------------------------
# Lock: prevent concurrent runs on this repo
# ---------------------------------------------------------------------------
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another worker is already running for $REPO_NAME (PID $LOCK_PID)"
        echo "If this is stale, remove: $LOCK_FILE"
        exit 1
    else
        echo "WARNING: Stale lock file found (PID $LOCK_PID no longer running). Removing."
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"

cleanup_lock() {
    rm -f "$LOCK_FILE"
}
trap cleanup_lock EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found in PATH"
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found in PATH"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq not found in PATH (required for state management)"
    echo "Install with: brew install jq"
    exit 1
fi

# ---------------------------------------------------------------------------
# Compute scope: which files to review
# ---------------------------------------------------------------------------

compute_scope() {
    local domain="$1"
    local last_commit
    last_commit=$(state_last_commit "$domain")
    local baseline_done
    baseline_done=$(state_baseline_complete "$domain")

    # Determine if we're in baseline mode
    local is_baseline=false
    if [[ "$BASELINE_MODE" == true ]]; then
        is_baseline=true
    elif [[ -z "$last_commit" && "$baseline_done" != "true" ]]; then
        is_baseline=true
    fi

    if [[ "$is_baseline" == true ]]; then
        echo "MODE: baseline" >&2

        # Check if we have remaining files from a previous baseline run
        local remaining_count
        remaining_count=$(state_baseline_remaining_count "$domain")

        if [[ "$BASELINE_MODE" == true && "$remaining_count" -gt 0 ]]; then
            # --baseline flag was used but we already have a partial baseline
            # Reset it for a fresh start
            echo "Resetting baseline for $domain (--baseline flag used)" >&2
            remaining_count=0
        fi

        if [[ "$remaining_count" -gt 0 ]]; then
            # Resume: take next batch from remaining files
            echo "Resuming baseline ($remaining_count files remaining)" >&2
            state_baseline_remaining "$domain" | head -n "$BATCH_SIZE"
        else
            # Fresh baseline: enumerate all relevant files
            local all_files
            if [[ "$domain" == "lint" || "$domain" == "types" ]]; then
                # shellcheck disable=SC2086
                all_files=$(cd "$REPO_DIR" && find $SOURCE_DIRS -name "*.py" \
                    -not -path "*/__pycache__/*" \
                    -not -path "*/alembic/*" \
                    2>/dev/null | sort)
            elif [[ "$domain" == "docs" ]]; then
                # All markdown files + Python files for docstring review
                all_files=$(cd "$REPO_DIR" && {
                    find . -maxdepth 2 -name "*.md" \
                        -not -path "./.git/*" \
                        -not -path "./.claude/*" 2>/dev/null
                    # shellcheck disable=SC2086
                    find $SOURCE_DIRS -name "*.py" \
                        -not -path "*/__pycache__/*" \
                        -not -path "*/alembic/*" 2>/dev/null
                } | sort -u)
            fi

            local total_count
            total_count=$(echo "$all_files" | wc -l | tr -d ' ')
            echo "Full baseline: $total_count files total" >&2

            # Store all files, return first batch
            local batch
            batch=$(echo "$all_files" | head -n "$BATCH_SIZE")
            local remaining
            remaining=$(echo "$all_files" | tail -n +"$((BATCH_SIZE + 1))")

            # Save remaining to state for next run
            if [[ -n "$remaining" ]]; then
                # shellcheck disable=SC2086
                state_set_baseline_remaining "$domain" $remaining
                echo "Batch: $BATCH_SIZE files ($(echo "$remaining" | wc -l | tr -d ' ') remaining for next run)" >&2
            else
                echo "Batch: $total_count files (all in one batch)" >&2
            fi

            echo "$batch"
        fi
    else
        echo "MODE: incremental" >&2

        # Incremental: only files changed since last review
        local changed_files=""
        if [[ "$domain" == "lint" || "$domain" == "types" ]]; then
            changed_files=$(cd "$REPO_DIR" && \
                git diff --name-only "$last_commit"..HEAD -- '*.py' 2>/dev/null | \
                grep -E "^($(echo "$SOURCE_DIRS" | tr ' ' '|' | sed 's/\///g'))" || true)
        elif [[ "$domain" == "docs" ]]; then
            changed_files=$(cd "$REPO_DIR" && {
                git diff --name-only "$last_commit"..HEAD -- '*.py' '*.md' 2>/dev/null
            } || true)
        fi

        if [[ -n "$changed_files" ]]; then
            echo "Changed since $last_commit: $(echo "$changed_files" | wc -l | tr -d ' ') files" >&2
        fi

        echo "$changed_files"
    fi
}

SCOPE_OUTPUT=$(compute_scope "$DOMAIN" 2>"$LOG_DIR/scope-stderr-${RUN_ID}.log")
SCOPE_MODE=$(grep "^MODE:" "$LOG_DIR/scope-stderr-${RUN_ID}.log" | head -1 | sed 's/^MODE: //')
SCOPE_INFO=$(grep -v "^MODE:" "$LOG_DIR/scope-stderr-${RUN_ID}.log" || true)

# Display scope info
if [[ -n "$SCOPE_INFO" ]]; then
    echo "$SCOPE_INFO"
fi

# Check if there's anything to do
if [[ -z "$SCOPE_OUTPUT" ]]; then
    echo ""
    echo "No files in scope for domain '$DOMAIN'. Nothing to do."
    CURRENT_HEAD=$(cd "$REPO_DIR" && git rev-parse HEAD)
    state_mark_reviewed "$DOMAIN" "$CURRENT_HEAD" "$DATE" "0"
    echo "Updated state: last_reviewed_commit → $CURRENT_HEAD"
    exit 0
fi

SCOPE_COUNT=$(echo "$SCOPE_OUTPUT" | wc -l | tr -d ' ')
echo ""
echo "Files in scope ($SCOPE_COUNT):"
echo "$SCOPE_OUTPUT" | sed 's/^/  - /'

# ---------------------------------------------------------------------------
# Dry run: show scope and exit
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "DRY RUN — would review $SCOPE_COUNT files for $DOMAIN domain"
    echo "Mode: $SCOPE_MODE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Create an isolated git worktree (never touches your main working directory)
# ---------------------------------------------------------------------------
cd "$REPO_DIR"

# Fetch latest default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || echo "WARNING: Could not fetch from origin"

# If a worktree from today already exists for this domain, check if it has unsaved work
if [[ -d "$WORKTREE_DIR" ]]; then
    echo "Found existing worktree from earlier today: $WORKTREE_DIR"

    if git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | grep -q .; then
        echo "WARNING: Existing worktree has UNCOMMITTED changes. Preserving it."
        echo "  -> Manual recovery: cd $WORKTREE_DIR"
        BRANCH_NAME="${QUALITY_BRANCH_PREFIX}/${DOMAIN}/${RUN_ID}"
        WORKTREE_DIR="$WORKTREE_BASE/${DOMAIN}-${RUN_ID}"
    else
        UNPUSHED=$(git -C "$WORKTREE_DIR" log --oneline @{u}..HEAD 2>/dev/null || echo "")
        if [[ -n "$UNPUSHED" ]]; then
            echo "WARNING: Existing worktree has UNPUSHED commits. Preserving it."
            echo "  -> Unpushed: $UNPUSHED"
            echo "  -> Manual recovery: cd $WORKTREE_DIR && git push"
            BRANCH_NAME="${QUALITY_BRANCH_PREFIX}/${DOMAIN}/${RUN_ID}"
            WORKTREE_DIR="$WORKTREE_BASE/${DOMAIN}-${RUN_ID}"
        else
            echo "Existing worktree is clean (all work pushed). Removing it."
            git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
            git branch -d "$BRANCH_NAME" 2>/dev/null || true
        fi
    fi
fi

git worktree prune 2>/dev/null || true

echo "Creating worktree at: $WORKTREE_DIR"
git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" 2>&1 || {
    echo "Branch $BRANCH_NAME already exists, retrying with run ID..."
    BRANCH_NAME="${QUALITY_BRANCH_PREFIX}/${DOMAIN}/${RUN_ID}"
    WORKTREE_DIR="$WORKTREE_BASE/${DOMAIN}-${RUN_ID}"
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "origin/$DEFAULT_BRANCH" 2>&1
}

echo "Working in isolated worktree: $WORKTREE_DIR"
echo "Branch: $BRANCH_NAME"

cd "$WORKTREE_DIR"

# Activate virtualenv if configured
if [[ -n "$VENV_PATH" && -f "$VENV_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$VENV_PATH"
    echo "Activated virtualenv: $VENV_PATH"
elif [[ -n "$VENV_PATH" ]]; then
    echo "WARNING: virtualenv not found at $VENV_PATH"
fi

# ---------------------------------------------------------------------------
# Assemble prompt
# ---------------------------------------------------------------------------

# Find prompt files (repo-specific overrides take precedence)
PROMPT_DIR="$SCRIPT_DIR/prompts"
PREAMBLE_FILE="$PROMPT_DIR/preamble.md"
DOMAIN_FILE="$PROMPT_DIR/${DOMAIN}.md"

if [[ ! -f "$PREAMBLE_FILE" ]]; then
    echo "ERROR: Preamble prompt not found: $PREAMBLE_FILE"
    exit 1
fi

if [[ ! -f "$DOMAIN_FILE" ]]; then
    echo "ERROR: Domain prompt not found: $DOMAIN_FILE"
    exit 1
fi

# Read and assemble prompt
PREAMBLE_CONTENT="$(cat "$PREAMBLE_FILE")"
DOMAIN_CONTENT="$(cat "$DOMAIN_FILE")"

# Substitute project-specific commands into domain prompt
DOMAIN_CONTENT=$(echo "$DOMAIN_CONTENT" | \
    sed -e "s|{LINT_COMMAND}|${LINT_COMMAND}|g" \
        -e "s|{LINT_FIX_COMMAND}|${LINT_FIX_COMMAND}|g" \
        -e "s|{TYPECHECK_COMMAND}|${TYPECHECK_COMMAND}|g" \
        -e "s|{TEST_COMMAND}|${TEST_COMMAND}|g" \
        -e "s|{MODE}|${SCOPE_MODE}|g")

FULL_PROMPT="${PREAMBLE_CONTENT}

${DOMAIN_CONTENT}

## SCOPE — files to review this run

Review ONLY these files (do not expand scope beyond this list):

$(echo "$SCOPE_OUTPUT" | sed 's/^/- /')

Total: ${SCOPE_COUNT} files"

# ---------------------------------------------------------------------------
# Run Claude Code (inside the worktree)
# ---------------------------------------------------------------------------
echo ""
echo "Launching Claude Code (with caffeinate to prevent sleep)..."
echo "Domain: $DOMAIN"
echo "Scope: $SCOPE_COUNT files"
echo ""

caffeinate -i -- \
    claude -p "$FULL_PROMPT" \
        --dangerously-skip-permissions \
        --verbose \
        2>&1

EXIT_CODE=$?

# ---------------------------------------------------------------------------
# Post-run: update state
# ---------------------------------------------------------------------------
cd "$REPO_DIR"

CURRENT_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD 2>/dev/null || git rev-parse HEAD)
state_mark_reviewed "$DOMAIN" "$CURRENT_HEAD" "$DATE" "$EXIT_CODE"
echo "Updated state: $DOMAIN → commit $CURRENT_HEAD"

# If baseline mode, update progress
if [[ "$SCOPE_MODE" == "baseline" ]]; then
    # Remove processed files from remaining
    # shellcheck disable=SC2086
    state_remove_from_baseline "$DOMAIN" $SCOPE_OUTPUT

    local_remaining=$(state_baseline_remaining_count "$DOMAIN")
    if [[ "$local_remaining" -eq 0 ]]; then
        state_mark_baseline_complete "$DOMAIN"
        echo "✓ Baseline complete for $DOMAIN domain!"
    else
        echo "Baseline progress: $local_remaining files remaining for $DOMAIN"
    fi
fi

# ---------------------------------------------------------------------------
# Safe cleanup: only remove worktree if all work is committed AND pushed
# ---------------------------------------------------------------------------
echo ""
echo "--- Post-run safety check ---"

SAFE_TO_REMOVE=true

if git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | grep -q .; then
    echo "⚠ Worktree has UNCOMMITTED changes — PRESERVING worktree."
    echo "  -> Recovery: cd $WORKTREE_DIR"
    SAFE_TO_REMOVE=false
fi

UNPUSHED=$(git -C "$WORKTREE_DIR" log --oneline @{u}..HEAD 2>/dev/null || echo "NO_UPSTREAM")
if [[ "$UNPUSHED" == "NO_UPSTREAM" ]]; then
    if git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null | grep -q .; then
        echo "✓ Branch exists on remote."
    else
        LOCAL_COMMITS=$(git -C "$WORKTREE_DIR" log --oneline "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "")
        if [[ -n "$LOCAL_COMMITS" ]]; then
            echo "⚠ Worktree has LOCAL-ONLY commits (never pushed) — PRESERVING worktree."
            echo "  -> Commits: $LOCAL_COMMITS"
            echo "  -> Recovery: cd $WORKTREE_DIR && git push -u origin HEAD"
            SAFE_TO_REMOVE=false
        fi
    fi
elif [[ -n "$UNPUSHED" ]]; then
    echo "⚠ Worktree has UNPUSHED commits — PRESERVING worktree."
    echo "  -> Unpushed: $UNPUSHED"
    echo "  -> Recovery: cd $WORKTREE_DIR && git push"
    SAFE_TO_REMOVE=false
fi

if [[ "$SAFE_TO_REMOVE" == true ]]; then
    echo "✓ All work committed and pushed. Removing worktree."
    git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
else
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  WORKTREE PRESERVED — has uncommitted or unpushed work  ║"
    echo "║  Path: $WORKTREE_DIR"
    echo "╚══════════════════════════════════════════════════════════╝"
fi

echo ""
echo "=========================================="
echo "Quality Worker finished — $REPO_NAME — $DOMAIN"
echo "Exit code: $EXIT_CODE"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

exit $EXIT_CODE
