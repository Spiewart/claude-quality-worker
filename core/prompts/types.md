## Domain: Type Annotations

You are adding and improving type annotations for function arguments and
return types. The goal is to progressively increase type coverage until
mypy can be configured with `disallow_untyped_defs = true`.

### Process

For each file in scope:

1. Examine every function and method definition:
   - Add return type annotations where missing (including `-> None`)
   - Add argument type annotations where missing
   - Replace `Any` with specific types where the actual type is clear
2. After annotating a file, run: `{TYPECHECK_COMMAND}`
3. Fix any type errors your annotations introduce.
4. Commit: `"types: annotate <module_name>"`

### Type Annotation Guidelines

**Modern Python syntax** (3.10+):
- Use `X | Y` for unions (not `Union[X, Y]` or `Optional[X]`)
- Use `list[T]`, `dict[K, V]`, `tuple[T, ...]` (not `List`, `Dict`, `Tuple`)
- Use `from __future__ import annotations` if the file needs forward references

**Project-specific conventions** (check CLAUDE.md):
- Time fields: `float` (seconds), not `timedelta`
- Path arguments: `Path | str` or `Path` alone (match existing convention)
- Pydantic models: Focus on standalone functions/methods — model fields
  already have types via Field declarations
- numpy arrays: Use `np.ndarray` (not `npt.NDArray[np.float64]` unless
  the project already uses that style)
- pandas: Use `pd.DataFrame`, `pd.Series`

**Inference from context**:
- Read the function body to determine correct types
- Check callers of the function for expected argument types
- Look at what the function returns to determine return type
- When genuinely ambiguous, prefer a broader type over a wrong one

**Protocol classes**:
- If you see duck-typed interfaces, use `typing.Protocol`
- But only if the project already uses this pattern

### What NOT to do

- Do NOT change function logic or behavior
- Do NOT rename parameters
- Do NOT add runtime type checking (isinstance guards for validation)
- Do NOT convert between `Optional[X]` and `X | None` if the file is
  internally consistent — follow the file's existing convention
- Do NOT add types to test files (they are excluded from mypy)
- Do NOT add overly specific generic types that reduce flexibility

### PR format

```
gh pr create --title "quality(types): annotate <N> files" --body "$(cat <<'EOF'
## Type Annotation Review

### Scope
- Mode: {MODE}
- Files annotated: {N}

### Changes
[list which files were annotated and how many functions in each]

### Verification
- [ ] `{TYPECHECK_COMMAND}` passes (or improves — note any pre-existing errors)
- [ ] `{TEST_COMMAND}` passes
- [ ] No runtime behavior changes

---
Generated automatically by claude-quality-worker (types domain)
EOF
)"
```
