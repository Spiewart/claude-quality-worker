# claude-quality-worker

Automated code quality enforcer powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Runs daily in the background to review and improve code quality across three domains:

- **Lint** — Automated fixes (ruff/flake8) + manual review for code smells, dead code, naming
- **Types** — Add missing type annotations to function args and returns, verify with mypy
- **Docs** — Fix documentation drift (docstrings, markdown files, examples)

Each run operates in an isolated git worktree and opens a PR for review.

## Quick Start

```bash
git clone https://github.com/Spiewart/claude-quality-worker.git
cd claude-quality-worker

# Install to a repo (auto-detects ruff, mypy, pytest from pyproject.toml)
./install.sh ~/my-project --venv ~/.virtualenvs/myenv/bin/activate

# Or with explicit commands
./install.sh ~/my-project \
  --lint-cmd "ruff check src/" \
  --typecheck-cmd "mypy src/" \
  --test-cmd "pytest tests/"
```

## Requirements

- macOS (uses launchd for scheduling)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude` command)
- [GitHub CLI](https://cli.github.com/) (`gh` command, authenticated)
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)

## How It Works

1. **Auto-rotates domains**: Each day picks the least-recently-run domain (lint → types → docs → lint → ...)
2. **Computes scope**: Uses `git diff` to find files changed since the last review (incremental mode), or enumerates all files in batches (baseline mode)
3. **Creates isolated worktree**: Never touches your main working directory
4. **Runs Claude Code**: Passes a domain-specific prompt with the scoped file list
5. **Opens a PR**: One PR per domain per run (e.g., `quality(types): annotate 12 files`)
6. **Updates state**: Tracks which commit was last reviewed per domain

## Usage

### Scheduled Runs (daily via launchd)

Runs automatically at the configured time (default: 3:00 AM). Domains auto-rotate.

### Manual / On-Demand

```bash
# Auto-select domain (picks oldest)
~/my-project/.claude/quality-worker/run.sh

# Target a specific domain
~/my-project/.claude/quality-worker/run.sh --domain types

# Force a comprehensive baseline review
~/my-project/.claude/quality-worker/run.sh --domain lint --baseline

# Preview what would be reviewed (no Claude invocation)
~/my-project/.claude/quality-worker/run.sh --domain docs --dry-run

# Control baseline batch size
~/my-project/.claude/quality-worker/run.sh --domain types --baseline --batch-size 25
```

### Background Run (without terminal)

```bash
launchctl kickstart gui/$(id -u)/com.claude.quality-worker.my-project
```

### Monitoring

```bash
# Watch live output
tail -f ~/my-project/.claude/quality-worker/logs/launchd-stdout.log

# Check if running
cat ~/my-project/.claude/quality-worker/.lock 2>/dev/null && echo "Running (PID $(cat ~/my-project/.claude/quality-worker/.lock))" || echo "Not running"

# View state
cat ~/my-project/.claude/quality-worker/state.json | jq .
```

### Pause / Resume

```bash
# Pause (unload agent)
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.claude.quality-worker.my-project.plist

# Resume (reload agent)
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.quality-worker.my-project.plist
```

## Baseline vs Incremental

### First Run (baseline)

When no prior state exists, the worker enters **baseline mode**:
- Enumerates all Python files in `SOURCE_DIRS`
- Processes them in batches (default: 15 files per run)
- Tracks progress in `state.json` — resumes where it left off
- Marks baseline complete when all files have been reviewed

### Subsequent Runs (incremental)

After baseline completes, the worker switches to **incremental mode**:
- Uses `git diff <last_reviewed_commit>..HEAD` to find changed files
- Reviews only files that have been modified since the last review
- If no files changed, skips the run (no empty PRs)

### Force Baseline

Use `--baseline` to reset and start a fresh comprehensive review:
```bash
~/my-project/.claude/quality-worker/run.sh --domain types --baseline
```

## Customization

### Per-Repo Config (`config.sh`)

Edit `~/my-project/.claude/quality-worker/config.sh`:

```bash
LINT_COMMAND="ruff check src/ cli/ tests/"
LINT_FIX_COMMAND="ruff check --fix src/ cli/"
TYPECHECK_COMMAND="mypy src/ cli/ --config-file=pyproject.toml"
TEST_COMMAND="python -m pytest tests/ -x -v --tb=short"
SOURCE_DIRS="src/ cli/"
DOC_FILES="CLAUDE.md GUI_README.md README.md"
DEFAULT_BATCH_SIZE=15
```

### Custom Prompts

Edit the prompt files in `~/my-project/.claude/quality-worker/prompts/`:
- `preamble.md` — Shared safety rules and workflow
- `lint.md` — Lint domain instructions
- `types.md` — Type annotation instructions
- `docs.md` — Documentation review instructions

Custom prompts are preserved across reinstalls.

## Auto-Wake

To wake your Mac before the scheduled run:

```bash
sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00
```

**Clamshell mode**: Must be plugged into power, or enable
*System Settings → Battery → Options → "Prevent your Mac from automatically sleeping when the display is off"*.

## Safety Guarantees

| Feature | How |
|---------|-----|
| **Worktree isolation** | All work in isolated worktree — never touches main directory |
| **Lock file** | PID-based, validates process is running, auto-clears stale locks |
| **No git stash** | Never used (stashes are global, cause cross-branch confusion) |
| **No force cleanup** | Never force-removes worktrees with uncommitted/unpushed work |
| **Sleep prevention** | `caffeinate -i` keeps Mac awake during the run |
| **Work preservation** | Failed runs preserve worktree + branch with recovery instructions |
| **State tracking** | Managed by bash, not Claude — always updated even if Claude fails |

### Recovering Preserved Worktrees

If a run fails and the worktree is preserved:

```bash
cd ~/my-project/.claude/quality-worker/worktrees/lint-2026-03-08
git status                    # See uncommitted changes
git push -u origin HEAD       # Push if needed
cd ~/my-project
git worktree remove .claude/quality-worker/worktrees/lint-2026-03-08
```

## Installed Files

| File | Location |
|------|----------|
| Worker script | `<repo>/.claude/quality-worker/run.sh` |
| State manager | `<repo>/.claude/quality-worker/state.sh` |
| Config | `<repo>/.claude/quality-worker/config.sh` |
| Prompts | `<repo>/.claude/quality-worker/prompts/*.md` |
| State | `<repo>/.claude/quality-worker/state.json` |
| Logs | `<repo>/.claude/quality-worker/logs/` |
| Worktrees | `<repo>/.claude/quality-worker/worktrees/` |
| Plist | `~/Library/LaunchAgents/com.claude.quality-worker.<name>.plist` |

## Uninstall

```bash
# Remove launchd agent only (keep files for manual runs)
./uninstall.sh ~/my-project

# Remove everything
./uninstall.sh ~/my-project --remove-files
```

## License

MIT
