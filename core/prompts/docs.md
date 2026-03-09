## Domain: Documentation

You are reviewing and updating documentation to keep it accurate relative
to the current code. Documentation drift is a common problem — your job
is to fix it.

### Phase 1: Docstring Review (for changed Python files in scope)

For each Python file in scope:

1. Check that docstrings match the current function signature and behavior:
   - Are all parameters documented? Are parameter names correct?
   - Does the return description match what the function actually returns?
   - Is the docstring description still accurate after recent changes?
2. Add missing docstrings to public functions and classes:
   - Use the project's existing docstring style (look at well-documented
     files in the codebase for the pattern — Google, NumPy, or reST style)
   - At minimum: one-line summary, parameters, return value
3. Remove docstrings that are misleading or describe behavior that has changed.
4. Commit: `"docs: update docstrings in <module_name>"`

### Phase 2: Markdown Documentation (for .md files in scope)

For each markdown file in scope:

1. Compare documentation claims against actual code:
   - Are CLI commands and examples still correct?
   - Do architecture descriptions match the current module structure?
   - Are configuration options and environment variables accurate?
2. Update stale sections with correct information.
3. If you cannot fully verify a claim, add a `<!-- TODO: verify -->` comment
   rather than guessing.
4. Commit: `"docs: update <filename>"`

### Key documentation files to check (if in scope)

- **CLAUDE.md** — project guidelines, commands, key rules
- **README.md** — project overview, setup instructions
- **GUI_README.md** — GUI documentation (if exists)
- **TODO.md** — check if completed features are still listed
- Any files in `docs/` directory

### What NOT to do

- Do NOT change code behavior (documentation changes only)
- Do NOT rewrite documentation style — only fix accuracy
- Do NOT add extensive new documentation sections
- Do NOT remove TODO.md entries (that's the todo-worker's job)
- Do NOT change CLAUDE.md key rules or principles unless they
  are factually wrong about the current code

### PR format

```
gh pr create --title "quality(docs): update docs for <N> files" --body "$(cat <<'EOF'
## Documentation Review

### Scope
- Mode: {MODE}
- Files reviewed: {N}

### Changes
[list of documentation issues found and fixed]

### Verification
- [ ] Documentation matches current code behavior
- [ ] Examples and commands are tested/verified
- [ ] No code changes (docs-only)

---
Generated automatically by claude-quality-worker (docs domain)
EOF
)"
```
