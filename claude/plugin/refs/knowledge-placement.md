# Where a fact goes

Every destination is paid for differently and the cheapest correct one wins. A
fact held in two of them is billed on every edit that loads both, and the copies
drift — so the question is never "is this worth writing down" but "which single
place does it belong".

| Content | Belongs in | Cost |
| --- | --- | --- |
| Anchored to one enforcement point: a measurement, an upstream bug, a silent-failure mode, what was already tried | a code comment | free until the file is opened |
| An invariant spanning several files, or a "don't undo this" that must land *before* the file is opened | a rule with `paths:` | full text on every matching edit |
| Applies everywhere, every session, and is short | `CLAUDE.md` | every session, every repo |
| A multi-step procedure, or anything task-triggered | a skill | only while that task runs |
| Must hold regardless of Claude's judgement | a PreToolUse hook | none — it is code |
| Detail too long to inline, behind a fact one of the above already states | a ref, linked by path | only when followed |
| Derivable by reading the codebase | nowhere — delete it | — |

**The comment is the default** — reach past it only when the fact has no single
enforcement point to sit next to.

**A rule states the invariant in one sentence and names the code that enforces
it**, instead of retelling reasoning a comment already holds. Scope `paths:` to
the files it can change a decision about: `src/**` bills every unrelated edit.

**A hard prohibition cannot live in a path-scoped rule.** Those vanish after
`/compact` until a matching file is read again, so "never do X" is unreliable
there — promote it to `CLAUDE.md`, or enforce it in a hook.

**A ref is not auto-discovered**, so whatever needs one links it by path. A
skill links this page rather than restating it.

## Reach — this repo or every repo

The layout is identical at both levels: `./.claude/<kind>/…` for this repo,
`~/.claude/<kind>/…` for every repo, across rules, refs, skills and hooks.
Project memory is the one that sits outside that shape, as `./CLAUDE.md` against
`~/.claude/CLAUDE.md`. Tool-level knowledge (Kubernetes, ArgoCD, Docker, crictl,
…) is the usual reason to go user level.

`~/.claude` is not a repository — its entries symlink into the dotfiles
checkout, so a user-level write never appears in the current project's
`git status` and needs `git -C`. Two deployed names differ from the tracked
ones: `~/.claude/CLAUDE.md` is `claude/global-instructions.md`, and the skills,
agents, refs and hooks of the `dotfiles` plugin live in `claude/plugin/` — a
submodule, its own repository (`ezintz/dotfiles-claude-plugin`), so a change
there is committed with `git -C ~/.dotfiles/claude/plugin` — linked as a whole
to `~/.claude/skills/dotfiles`.

## Before writing anything

Check whether a code comment already carries the fact. It usually does, and that
is usually where it should stay. When the same fact sits in two places, keep the
comment and delete the rest — unless it is a prohibition that has to land before
the file is opened, which belongs in `CLAUDE.md` or a hook instead. When two
rules carry it, merge into the one whose `paths:` actually covers it.
