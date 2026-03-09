#!/usr/bin/env bash
# =============================================================================
# claude-quality-worker — Install to a target repo
#
# Usage:
#   ./install.sh ~/path/to/repo [options]
#
# Options:
#   --venv PATH           Path to virtualenv activate script
#   --hour N              Schedule hour (0-23, default: 3)
#   --minute N            Schedule minute (0-59, default: 0)
#   --prefix NAME         Branch prefix (default: "quality")
#   --timeout N           Max run time in seconds (default: 7200)
#   --no-schedule         Install files only, skip launchd setup
#   --lint-cmd CMD        Override lint check command
#   --lint-fix-cmd CMD    Override lint fix command
#   --typecheck-cmd CMD   Override type check command
#   --test-cmd CMD        Override test command
#   --source-dirs DIRS    Override source directories (space-separated)
#   --doc-files FILES     Override doc files (space-separated)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
REPO_DIR=""
VENV_PATH=""
HOUR=3
MINUTE=0
BRANCH_PREFIX="quality"
TIMEOUT=7200
SKIP_SCHEDULE=false

# Override flags (empty = auto-detect)
OPT_LINT_CMD=""
OPT_LINT_FIX_CMD=""
OPT_TYPECHECK_CMD=""
OPT_TEST_CMD=""
OPT_SOURCE_DIRS=""
OPT_DOC_FILES=""

usage() {
    echo "Usage: $0 <repo-path> [options]"
    echo ""
    echo "Arguments:"
    echo "  repo-path              Path to the git repository"
    echo ""
    echo "Options:"
    echo "  --venv PATH            Path to virtualenv activate script"
    echo "  --hour N               Schedule hour (0-23, default: 3)"
    echo "  --minute N             Schedule minute (0-59, default: 0)"
    echo "  --prefix NAME          Branch prefix (default: \"quality\")"
    echo "  --timeout N            Max run time in seconds (default: 7200)"
    echo "  --no-schedule          Install files only, skip launchd setup"
    echo "  --lint-cmd CMD         Lint check command (overrides auto-detect)"
    echo "  --lint-fix-cmd CMD     Lint fix command (overrides auto-detect)"
    echo "  --typecheck-cmd CMD    Type check command (overrides auto-detect)"
    echo "  --test-cmd CMD         Test command (overrides auto-detect)"
    echo "  --source-dirs DIRS     Source directories (overrides auto-detect)"
    echo "  --doc-files FILES      Doc files to track (overrides auto-detect)"
    echo "  --help, -h             Show this help"
    exit 0
}

if [[ $# -eq 0 ]]; then
    usage
fi

REPO_DIR="$(cd "$1" && pwd)"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --venv)           VENV_PATH="$2"; shift 2 ;;
        --hour)           HOUR="$2"; shift 2 ;;
        --minute)         MINUTE="$2"; shift 2 ;;
        --prefix)         BRANCH_PREFIX="$2"; shift 2 ;;
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        --no-schedule)    SKIP_SCHEDULE=true; shift ;;
        --lint-cmd)       OPT_LINT_CMD="$2"; shift 2 ;;
        --lint-fix-cmd)   OPT_LINT_FIX_CMD="$2"; shift 2 ;;
        --typecheck-cmd)  OPT_TYPECHECK_CMD="$2"; shift 2 ;;
        --test-cmd)       OPT_TEST_CMD="$2"; shift 2 ;;
        --source-dirs)    OPT_SOURCE_DIRS="$2"; shift 2 ;;
        --doc-files)      OPT_DOC_FILES="$2"; shift 2 ;;
        --help|-h)        usage ;;
        *)                echo "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "ERROR: $REPO_DIR is not a git repository"
    exit 1
fi

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for state management"
    echo "Install with: brew install jq"
    exit 1
fi

REPO_NAME="$(basename "$REPO_DIR")"
WORKER_DIR="$REPO_DIR/.claude/quality-worker"
LABEL="com.claude.quality-worker.${REPO_NAME}"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

# ---------------------------------------------------------------------------
# Auto-detect project tools from pyproject.toml
# ---------------------------------------------------------------------------
PYPROJECT="$REPO_DIR/pyproject.toml"
DETECTED_NOTE="Edit these to match your project"

detect_tools() {
    if [[ ! -f "$PYPROJECT" ]]; then
        echo "No pyproject.toml found — using defaults"
        return
    fi

    echo "Scanning pyproject.toml for project tools..."
    DETECTED_NOTE="Auto-detected from pyproject.toml (edit freely)"

    # Detect ruff
    if grep -q '\[tool\.ruff\]' "$PYPROJECT" 2>/dev/null; then
        echo "  ✓ Found ruff configuration"
        if [[ -z "$OPT_LINT_CMD" ]]; then
            OPT_LINT_CMD="ruff check src/ cli/ tests/"
        fi
        if [[ -z "$OPT_LINT_FIX_CMD" ]]; then
            OPT_LINT_FIX_CMD="ruff check --fix src/ cli/"
        fi
    fi

    # Detect mypy
    if grep -q '\[tool\.mypy\]' "$PYPROJECT" 2>/dev/null; then
        echo "  ✓ Found mypy configuration"
        if [[ -z "$OPT_TYPECHECK_CMD" ]]; then
            OPT_TYPECHECK_CMD="mypy src/ cli/ --config-file=pyproject.toml"
        fi
    fi

    # Detect pytest
    if grep -qE '\[tool\.pytest' "$PYPROJECT" 2>/dev/null; then
        echo "  ✓ Found pytest configuration"
        if [[ -z "$OPT_TEST_CMD" ]]; then
            OPT_TEST_CMD="python -m pytest tests/ -x -v --tb=short"
        fi
    fi

    # Detect pylint
    if grep -q '\[tool\.pylint\]' "$PYPROJECT" 2>/dev/null; then
        echo "  ✓ Found pylint configuration"
        if [[ -z "$OPT_LINT_CMD" ]]; then
            OPT_LINT_CMD="pylint src/"
        fi
    fi

    # Detect pyright
    if grep -q '\[tool\.pyright\]' "$PYPROJECT" 2>/dev/null; then
        echo "  ✓ Found pyright configuration"
        if [[ -z "$OPT_TYPECHECK_CMD" ]]; then
            OPT_TYPECHECK_CMD="pyright src/"
        fi
    fi
}

detect_source_dirs() {
    if [[ -n "$OPT_SOURCE_DIRS" ]]; then
        return  # User override
    fi

    local dirs=""
    for d in src cli lib app; do
        if [[ -d "$REPO_DIR/$d" ]]; then
            dirs="$dirs $d/"
        fi
    done
    if [[ -n "$dirs" ]]; then
        OPT_SOURCE_DIRS="$(echo "$dirs" | sed 's/^ //')"
        echo "  ✓ Detected source dirs: $OPT_SOURCE_DIRS"
    else
        OPT_SOURCE_DIRS="src/"
        echo "  ⚠ No standard source dirs found, defaulting to: src/"
    fi
}

detect_doc_files() {
    if [[ -n "$OPT_DOC_FILES" ]]; then
        return  # User override
    fi

    local docs=""
    for f in README.md CLAUDE.md GUI_README.md CONTRIBUTING.md CHANGELOG.md; do
        if [[ -f "$REPO_DIR/$f" ]]; then
            docs="$docs $f"
        fi
    done
    if [[ -d "$REPO_DIR/docs" ]]; then
        docs="$docs docs/"
    fi
    if [[ -n "$docs" ]]; then
        OPT_DOC_FILES="$(echo "$docs" | sed 's/^ //')"
        echo "  ✓ Detected doc files: $OPT_DOC_FILES"
    else
        OPT_DOC_FILES="README.md"
        echo "  ⚠ No doc files found, defaulting to: README.md"
    fi
}

detect_tools
detect_source_dirs
detect_doc_files

# Apply defaults for anything not detected or overridden
LINT_CMD="${OPT_LINT_CMD:-ruff check src/}"
LINT_FIX_CMD="${OPT_LINT_FIX_CMD:-ruff check --fix src/}"
TYPECHECK_CMD="${OPT_TYPECHECK_CMD:-mypy src/}"
TEST_CMD="${OPT_TEST_CMD:-python -m pytest tests/ -x -v --tb=short}"
SOURCE_DIRS="${OPT_SOURCE_DIRS:-src/}"
DOC_FILES="${OPT_DOC_FILES:-README.md}"

echo ""
echo "=========================================="
echo "claude-quality-worker — Installing"
echo "=========================================="
echo "Repo:       $REPO_DIR"
echo "Name:       $REPO_NAME"
echo "Schedule:   ${HOUR}:$(printf '%02d' "$MINUTE") daily"
echo "Branch:     ${BRANCH_PREFIX}/<domain>/YYYY-MM-DD"
echo "Venv:       ${VENV_PATH:-none}"
echo "Label:      $LABEL"
echo ""
echo "Detected commands:"
echo "  Lint:      $LINT_CMD"
echo "  Lint fix:  $LINT_FIX_CMD"
echo "  Typecheck: $TYPECHECK_CMD"
echo "  Test:      $TEST_CMD"
echo "  Sources:   $SOURCE_DIRS"
echo "  Docs:      $DOC_FILES"
echo ""

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------
echo "Creating directory structure..."
mkdir -p "$WORKER_DIR/logs" "$WORKER_DIR/worktrees" "$WORKER_DIR/prompts"

# ---------------------------------------------------------------------------
# Install run.sh and state.sh
# ---------------------------------------------------------------------------
echo "Installing run.sh..."
cp "$SCRIPT_DIR/core/run.sh" "$WORKER_DIR/run.sh"
chmod +x "$WORKER_DIR/run.sh"

echo "Installing state.sh..."
cp "$SCRIPT_DIR/core/state.sh" "$WORKER_DIR/state.sh"
chmod +x "$WORKER_DIR/state.sh"

# ---------------------------------------------------------------------------
# Install prompts (only if not already customized)
# ---------------------------------------------------------------------------
for prompt_file in preamble.md lint.md types.md docs.md; do
    if [[ -f "$WORKER_DIR/prompts/$prompt_file" ]]; then
        echo "Keeping existing prompts/$prompt_file (custom version found)"
    else
        echo "Installing prompts/$prompt_file..."
        cp "$SCRIPT_DIR/core/prompts/$prompt_file" "$WORKER_DIR/prompts/$prompt_file"
    fi
done

# ---------------------------------------------------------------------------
# Generate config.sh
# ---------------------------------------------------------------------------
if [[ -f "$WORKER_DIR/config.sh" ]]; then
    echo "Keeping existing config.sh"
else
    echo "Generating config.sh..."
    sed -e "s|__REPO_NAME__|$REPO_NAME|g" \
        -e "s|__VENV_PATH__|$VENV_PATH|g" \
        -e "s|__BRANCH_PREFIX__|$BRANCH_PREFIX|g" \
        -e "s|__DETECTED_NOTE__|$DETECTED_NOTE|g" \
        -e "s|__LINT_COMMAND__|$LINT_CMD|g" \
        -e "s|__LINT_FIX_COMMAND__|$LINT_FIX_CMD|g" \
        -e "s|__TYPECHECK_COMMAND__|$TYPECHECK_CMD|g" \
        -e "s|__TEST_COMMAND__|$TEST_CMD|g" \
        -e "s|__SOURCE_DIRS__|$SOURCE_DIRS|g" \
        -e "s|__DOC_FILES__|$DOC_FILES|g" \
        "$SCRIPT_DIR/templates/config.sh.tpl" > "$WORKER_DIR/config.sh"
fi

# ---------------------------------------------------------------------------
# Initialize state.json (if not present)
# ---------------------------------------------------------------------------
if [[ ! -f "$WORKER_DIR/state.json" ]]; then
    echo "Creating initial state.json..."
    cp "$SCRIPT_DIR/templates/state.json.tpl" "$WORKER_DIR/state.json"
fi

# ---------------------------------------------------------------------------
# Ensure .claude is gitignored
# ---------------------------------------------------------------------------
GITIGNORE="$REPO_DIR/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
    if ! grep -q "\.claude" "$GITIGNORE" 2>/dev/null; then
        echo "Adding .claude to .gitignore..."
        echo ".claude" >> "$GITIGNORE"
    fi
else
    echo "Creating .gitignore with .claude entry..."
    echo ".claude" > "$GITIGNORE"
fi

# ---------------------------------------------------------------------------
# Generate and load launchd plist
# ---------------------------------------------------------------------------
if [[ "$SKIP_SCHEDULE" == true ]]; then
    echo "Skipping launchd setup (--no-schedule)"
else
    echo "Generating launchd plist..."

    # Unload existing agent if present
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true

    sed -e "s|__LABEL__|$LABEL|g" \
        -e "s|__REPO_DIR__|$REPO_DIR|g" \
        -e "s|__HOUR__|$HOUR|g" \
        -e "s|__MINUTE__|$MINUTE|g" \
        -e "s|__HOME__|$HOME|g" \
        -e "s|__TIMEOUT__|$TIMEOUT|g" \
        "$SCRIPT_DIR/templates/launchd.plist.tpl" > "$PLIST_PATH"

    echo "Loading launchd agent..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    echo "✓ Agent loaded: $LABEL"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "✓ Installation complete!"
echo "=========================================="
echo ""
echo "Manual run (auto-rotate domain):"
echo "  $WORKER_DIR/run.sh"
echo ""
echo "Target a specific domain:"
echo "  $WORKER_DIR/run.sh --domain lint"
echo "  $WORKER_DIR/run.sh --domain types"
echo "  $WORKER_DIR/run.sh --domain docs"
echo ""
echo "Force baseline review:"
echo "  $WORKER_DIR/run.sh --domain types --baseline"
echo ""
echo "Dry run (show scope without running Claude):"
echo "  $WORKER_DIR/run.sh --domain lint --dry-run"
echo ""
if [[ "$SKIP_SCHEDULE" != true ]]; then
    echo "Background run:"
    echo "  launchctl kickstart gui/\$(id -u)/$LABEL"
    echo ""
    echo "Monitor:"
    echo "  tail -f $WORKER_DIR/logs/launchd-stdout.log"
    echo ""
    echo "Pause/resume:"
    echo "  launchctl bootout gui/\$(id -u) $PLIST_PATH"
    echo "  launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
    echo ""
fi
echo "Customize prompts:"
echo "  $WORKER_DIR/prompts/"
echo ""
echo "Customize config:"
echo "  $WORKER_DIR/config.sh"
echo ""

# Check for pmset wake schedule
if ! pmset -g sched 2>/dev/null | grep -q "wake"; then
    echo "────────────────────────────────────────"
    echo "TIP: Set up auto-wake so your Mac is awake for the scheduled run:"
    echo "  sudo pmset repeat wakeorpoweron MTWRFSU $(printf '%02d' $((HOUR > 0 ? HOUR - 1 : 23))):55:00"
    echo "────────────────────────────────────────"
fi
