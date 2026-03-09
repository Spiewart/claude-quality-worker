## Domain: Linting

You are reviewing code for linting quality. Your scope goes BEYOND what
automated tools catch — you are the human-level reviewer.

### Phase 1: Automated Fixes (do first)

1. Run: `{LINT_FIX_COMMAND}`
2. If any files were auto-fixed, commit them separately:
   ```
   git add -A && git commit -m "fix: automated lint fixes (ruff)"
   ```
3. Run: `{LINT_COMMAND}` to verify no remaining automated issues.

### Phase 2: Manual Review (after automated fixes)

For each file in scope, review for issues that automated tools miss:

- **Naming**: Are function/variable/class names clear and consistent with
  project conventions? (snake_case for functions/vars, PascalCase for classes)
- **Code smells**: Overly complex conditionals, deeply nested logic,
  functions doing too many things, magic numbers without named constants
- **Dead code**: Unused imports that ruff missed, unreachable branches,
  commented-out code blocks that should be removed
- **Pattern violations**: Logic that should go through established patterns
  but is hardcoded (check CLAUDE.md for project-specific patterns)
- **Error handling**: Bare `except:` clauses, swallowed exceptions,
  missing error context in exception messages
- **Consistency**: Mixed styles within the same module (e.g., some functions
  use early returns while others use deep nesting)

### What NOT to do

- Do NOT change function signatures or public APIs
- Do NOT refactor architecture or module boundaries
- Do NOT add features or new functionality
- Do NOT modify test assertions (only fix lint issues in test files)
- Do NOT rewrite working code just because you'd write it differently

### Commit and PR

Commit manual fixes with: `"lint: clean up <module_name>"`

PR format:
```
gh pr create --title "quality(lint): review <N> files" --body "$(cat <<'EOF'
## Lint Review

### Scope
- Mode: {MODE}
- Files reviewed: {N}

### Changes
[bullet list of issues found and fixed, grouped by file]

### Verification
- [ ] `{LINT_COMMAND}` passes
- [ ] `{TEST_COMMAND}` passes
- [ ] No behavior changes

---
Generated automatically by claude-quality-worker (lint domain)
EOF
)"
```
