#!/usr/bin/env bash
# =============================================================================
# claude-quality-worker — Example config.sh
#
# This file is sourced by run.sh. All values are shell variables.
# Copy to <repo>/.claude/quality-worker/config.sh and customize.
# =============================================================================

# --- Virtual environment ---
# Path to virtualenv activate script (leave empty to skip)
# Examples:
#   VENV_PATH="$HOME/.virtualenvs/myenv/bin/activate"
#   VENV_PATH="$HOME/myrepo/.venv/bin/activate"
VENV_PATH=""

# --- Git ---
# Branch prefix for quality branches
# Creates: quality/lint/YYYY-MM-DD, quality/types/YYYY-MM-DD, etc.
QUALITY_BRANCH_PREFIX="quality"

# How many days to keep log files before auto-deletion
LOG_RETENTION_DAYS=30

# --- Quality tool commands ---
# These are substituted into the domain prompts as {LINT_COMMAND}, etc.
# Adjust to match your project's tooling.

# Lint checker (ruff, flake8, pylint, etc.)
LINT_COMMAND="ruff check src/ cli/ tests/"

# Lint auto-fixer (run before manual review)
LINT_FIX_COMMAND="ruff check --fix src/ cli/"

# Type checker (mypy, pyright, pytype, etc.)
TYPECHECK_COMMAND="mypy src/ cli/ --config-file=pyproject.toml"

# Test runner
TEST_COMMAND="python -m pytest tests/ -x -v --tb=short"

# --- Scope ---
# Source directories to scan for Python files (space-separated)
SOURCE_DIRS="src/ cli/"

# Documentation files/directories to track (space-separated)
# Used by the docs domain to check for stale documentation
DOC_FILES="CLAUDE.md GUI_README.md README.md docs/"

# Max files per baseline batch
# Controls how many files Claude reviews per session during baseline mode.
# Higher = faster baseline completion, but risks context overflow.
# Recommended: 10-20 for most projects.
DEFAULT_BATCH_SIZE=15
