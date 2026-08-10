---
name: rule-reviewer
description: Reviews a project's `.claude/rules/` files against Claude Code's rules spec — path scoping, the always-on context budget, glob correctness, cross-rule conflicts, and whether the content is derivable from the codebase. Use when asked to review, audit, trim or sharpen rules; when CLAUDE.md or the rules directory feels bloated; when deciding whether something belongs in a rule, CLAUDE.md, a skill or a hook; or after adding, renaming or reorganising rule files.
allowed-tools: Read Grep Glob Bash WebFetch
---

# Rule Reviewer

Reviews `.claude/rules/*.md` and the CLAUDE.md files they support. Rules are
context, not enforcement — every finding is about whether a line earns the
tokens it costs and whether it loads at the moment it is needed.

Distinguish hard requirements from judgement calls, and say which is which.

## Loading Mechanics

Every finding follows from these. Check them before judging any content.

- A rule **without** `paths` loads at launch, with the same priority as
  `.claude/CLAUDE.md`. It costs tokens in every session forever.
- A rule **with** `paths` loads when Claude *reads a file matching the pattern* —
  not on every tool use, and not merely because the topic came up.
- `.md` files are discovered recursively, so subdirectories are fine. Symlinks
  are resolved, so a shared rule set can be linked in from elsewhere.
- User rules in `~/.claude/rules/` load before project rules; project rules win.
- **After `/compact`, path-scoped rules are not re-injected.** They reload only
  when a matching file is next read. Project-root CLAUDE.md is re-read from disk.
- Rules shape behaviour but do not enforce it. Anything that must hold
  regardless of what Claude decides belongs in a PreToolUse hook.

## Review Criteria

### 1. Frontmatter

`paths` is the entire schema. There is no `name`, `description`, `enabled` or
`priority` field — any other key is inert. Flag it as dead config rather than a
violation, since it is silently ignored.

Glob rules worth checking:
- Brace expansion multiplies: `{a,b}/{c,d}/*.{ts,tsx}` is eight patterns. A
  rule's whole `paths` list shares one budget of 1,000 expanded patterns and
  4 MiB. **A pattern that would exceed the budget is used unexpanded**, so its
  literal braces match nothing — the rule goes silently dead.
- `[` starts a bracket expression. A pattern like `photos [2024/**` is invalid
  and matches nothing; escape it as `photos \[2024/**`.
- Confirm each pattern matches real files. A glob that matches nothing is a rule
  that never loads, and nothing reports it.

### 2. The always-on budget

Sum the line counts of every unscoped rule and add the project CLAUDE.md files.
That total is what loads in every session. The documented target is under 200
lines per CLAUDE.md file, and unscoped rules share its priority, so treat the
combined figure as the number to defend.

For each unscoped rule ask: is this relevant when Claude is working *anywhere*
in the repo? If it is relevant only to some paths, it wants `paths`. If it is
relevant only to some tasks, it wants to be a skill.

### 3. Derivability — the sharpness test

This is the main quality lever. `/doctor` uses the same heuristic when it
proposes trims:

- **Cut** what Claude can read off the codebase: directory layouts, dependency
  lists, architecture overviews, restated file names, API signatures, anything
  that duplicates a README or a config file.
- **Keep** pitfalls, rationale, and conventions that differ from tool defaults —
  the things Claude gets wrong precisely because the code does not say them.

A rule that describes the system is usually cuttable. A rule that says "this
looks like X but you must do Y, because Z" is the reason rules exist.

### 4. The recovery test — apply before proposing any cut

Derivability says the knowledge exists elsewhere. It does not say the knowledge
*arrives*. A cut is only safe when what you removed comes back through something
that fires on its own:

- **Another loading path** — an always-on rule, or a differently-scoped rule
  covering the same files. Skills count too: their descriptions are listed every
  session, so routing a runbook to a skill is a real deferral, not a discard.
- **A tool that fails loudly at the moment it matters** — commitlint rejects the
  commit, the linter rejects the file, the type checker rejects the build. The
  loop closes exactly when the knowledge is needed.
- **The source of truth Claude would open anyway** — cutting a restated port
  list is safe because `docker-compose.yml` is the authority and gets read while
  working on the thing it describes.

**A pointer to `docs/*.md` is none of these.** Nothing triggers the read, so
"move it to `docs/` and link it" deletes the knowledge and adds a step. Reserve
that move for depth *beneath* content the rule keeps — never as the destination
for a pitfall the rule currently carries.

The question that settles it: if this rule vanished, what teaches Claude this
again, and does it happen before or after the mistake? After is not recovery.
Pitfalls almost never survive a cut, because the whole reason they are written
down is that nothing else surfaces them in time.

### 5. Cross-rule conflicts

Collect every `paths` pattern and find overlaps. Rules with overlapping globs
load together, and contradictions between them are resolved arbitrarily. Report
each overlapping set and whether the rules actually disagree.

Also check for the same instruction stated in two files, and for a rule
restating something already in CLAUDE.md.

### 6. Verifiability

Instructions must be concrete enough to check. Prefer "run `npm test` before
committing" over "test your changes"; "use 2-space indentation" over "format
code properly". Vague guidance costs tokens and changes nothing.

### 7. Placement — should this be a rule at all?

| Content | Belongs in |
| --- | --- |
| Applies everywhere, every session, short | `CLAUDE.md` |
| Applies to a subset of files | rule with `paths` |
| A multi-step procedure, or task-triggered | a skill |
| Must hold regardless of Claude's judgement | a PreToolUse hook |
| Derivable from the codebase | nowhere — delete it |
| Background depth behind a fact the rule keeps | `docs/`, linked from the rule |

The `docs/` row is narrow on purpose. It holds the long incident writeup once
the rule states the conclusion — not the conclusion itself.

Flag any path-scoped rule carrying a hard constraint. Because path-scoped rules
vanish after `/compact` until a matching file is read again, a "never do X" rule
is unreliable in that position — promote it to CLAUDE.md, or enforce it in a hook.

## Anti-Patterns to Flag

- ❌ Unscoped rule that only applies to part of the repo
- ❌ Architecture overview, directory tree or dependency list as a rule
- ❌ Hard prohibition living in a path-scoped rule
- ❌ `paths` glob that matches no files, or braces that blow the expansion budget
- ❌ Frontmatter keys other than `paths` (silently ignored)
- ❌ Two rules with overlapping globs giving conflicting instructions
- ❌ Vague guidance that cannot be verified
- ❌ Content duplicated between a rule and CLAUDE.md
- ❌ Development notes: changelogs, timestamps, "validated on…", TODOs
- ❌ Hardcoded credentials, tokens or API keys
- ❌ Absolute paths (`/Users/…`, `C:\Users\…`) or machine-specific hostnames
- ❌ A rule that is really a procedure and should be a skill

And two anti-patterns in the review itself, not the rules:

- ❌ Proposing a cut whose only recovery is "see `docs/…`" — nothing loads it
- ❌ Cutting a pitfall because it is documented somewhere; documented is not loaded

## Process

Start with the bundled analyser. It settles everything mechanical — the budget,
glob validity, overlaps, hygiene — so your attention goes to the judgement calls
it cannot make. Counting lines and expanding globs by hand invites transcription
errors and gives a different answer each run.

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/analyze_rules.py" <repo-root>       # human-readable
python3 "${CLAUDE_SKILL_DIR}/scripts/analyze_rules.py" <repo-root> --json  # machine-readable
```

It reports: the always-on budget against the 200-line target, every pattern with
its match count, dead globs, invalid bracket expressions, over-budget brace
expansion, ignored frontmatter keys, overlapping patterns, and hygiene hits.

Then do the parts that need reading:

1. Read every rule file, plus every CLAUDE.md that loads alongside them. The
   analyser counts lines; only you can judge what the lines say.
2. Apply the derivability test to every section — cut what the codebase already
   states.
3. For each overlapping set the analyser found, decide whether the rules
   actually contradict each other or merely coexist.
4. Check verifiability, then placement against the table above.
5. Triage the hygiene hits. The analyser matches patterns, not meaning, so each
   one needs a call. A **live secret** is a finding — rules are committed and
   shared, so treat them as public within the organisation and keep only the
   variable name. A **service identifier** (Jira cloud ID, project key, site
   URL) is fine; those are the non-derivable facts rules exist to hold. An
   **absolute path** is a portability bug, not a security one — make it relative.
6. Read `references/output-format.md` and write the review to that template.
   Lead with the context budget, and quantify each cut in lines removed from the
   always-on total — that is the number the user feels.

## Reference Documentation

- Rules, CLAUDE.md and loading order: https://code.claude.com/docs/en/memory
- What survives compaction: https://code.claude.com/docs/en/context-window
- Hooks, for constraints that must be enforced: https://code.claude.com/docs/en/hooks

Fetch the docs when a claim is load-bearing. Do not review from memory — the
rules feature is young and its behaviour has changed across releases.
