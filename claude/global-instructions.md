
# Current shell

- `>` will not overwrite: `unsetopt CLOBBER` is set, use `>|` to truncate
  on purpose.
- `cp`, `mv`, `rm` are aliased to `-i`, bypass alias: `command mv -f old new`.
- **Unquoted `$var` does not word-split** (zsh's default, not a setting here), so
  a multi-word value stays one argument and a loop meant to fan out collapses
  silently rather than erroring. Use `${=var}` or an array to split on purpose.

## Knowledge / Memory

**A comment carries what the code cannot** — never a restated name, signature or control flow.
Delete one that does, including a pre-existing one.

**Nothing read on its own — comment, rule, skill, PRD, story, issue — may hold its meaning
in a pointer.**
"See docs/plan.md §2c", "Phase 2", "as discussed above" are empty to a reader without that
context; whatever is then unrecoverable was never in it. Write the reasoning in, demote references
to provenance (parentheses or a `Refs:` trailer), and name things by what they are — "Supercharger
(the batch-import path)", not "the wrapper we added".

# .NET (Homebrew install)

- **`strings` finds no managed string in a .NET assembly.** They are stored
  UTF-16LE, so an ASCII scan reports nothing — which reads as "this code was
  never packaged" rather than "wrong tool". Search the raw bytes for the encoded
  form instead: `s.encode("utf-16-le") in open(dll, "rb").read()`.

# Python (Homebrew install)

- **`pip install` is refused, not broken** (PEP 668, never
  `--break-system-packages`): `uv run --with <pkg> script.py`, or
  `uv venv && uv pip install <pkg>` when a venv on disk is really needed.

# Git

- **Three dots, not two, against a base branch**: `git diff main...HEAD` uses
  the merge-base, as `gh pr diff` and `glab mr diff` do.
- **`.claude/worktrees/` is a second checkout of the repo**, so a scan that
  doesn't skip it double-counts every file and reports each rule twice as if
  duplicated. `rg` skips it; `find`, `ls`, `du` and `grep -r` do not. Prefer
  `git ls-files`; with `find`, add `-not -path './.claude/*'`.
