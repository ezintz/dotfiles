---
name: rule-reviewer
description: Reviews a project's `.claude/rules/` files against Claude Code's rules spec — path scoping, the always-on context budget, glob correctness, cross-rule conflicts, and whether the content is derivable from the codebase or already stated in the code comments it duplicates. Use when asked to review, audit, trim, dedup or sharpen rules; when CLAUDE.md or the rules directory feels bloated or context cost is a concern; when deciding whether a fact belongs in a rule, a code comment, CLAUDE.md, a skill or a hook; or after adding, growing, renaming or reorganising rule files.
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

### 2. The budget — always-on and per-edit

Sum the line counts of every unscoped rule and add the project CLAUDE.md files.
That total is what loads in every session. The documented target is under 200
lines per CLAUDE.md file, and unscoped rules share its priority, so treat the
combined figure as the number to defend.

For each unscoped rule ask: is this relevant when Claude is working *anywhere*
in the repo? If it is relevant only to some paths, it wants `paths`. If it is
relevant only to some tasks, it wants to be a skill.

A scoped rule has a second budget the always-on total never shows: it is
injected **in full** on every edit to every file its globs match. Compare the
analyser's match count against the number of files the rule actually discusses.
A rule of 30 lines about one client library's retry semantics, scoped to
`src/**`, bills every source file in the tree for knowledge that concerns a
handful — scoped, entirely legitimate content, and still the most expensive
thing in the directory.

Two shapes to flag:

- **A glob far broader than the subject** — a whole project directory or
  `src/**` when the rule names a handful of files. Narrowing costs nothing.
- **A large rule scoped onto a hot file.** A 3,000-word rule pinned to the one
  file every feature touches is paid on every unrelated edit to it. If only one
  section concerns that file, split the rule and scope the halves separately.

Report per-edit cost as the mean rule words loaded per matching file, before
and after. That is the number the user feels on ordinary work.

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

### 5. Density — the form of what survives

Derivability decides whether content stays; density decides what it costs once
it does, since a rule is re-injected in full on every matching edit.

- **Bullets, not prose.** An instruction and its reason belong on one bullet,
  joined by an em dash — not a narrative paragraph with the rule buried in it.
- **Flag any rule paragraph that restates a code comment.** `comment-inventory.py
  --rule <name>` prints the comments from exactly the files that rule is charged
  against; `--overlap` ranks them against the rule's own bullets. When the
  comment at the enforcement point is the fuller copy — it usually is, since it
  carries the actual numbers — the rule keeps a one-line invariant plus a
  pointer, and drops the retelling.
- **Prose is not automatically a finding.** War stories that span several files,
  or that no single enforcement point owns, have nowhere better to live. The
  test is whether a specific file already says it, not whether it reads long.

This is a rewrite, not a cut, so the recovery test above is satisfied by
construction — the invariant stays in the rule. Quantify it as words removed.

### 6. Cross-rule conflicts

Collect every `paths` pattern and find overlaps. Rules with overlapping globs
load together, and contradictions between them are resolved arbitrarily. Report
each overlapping set and whether the rules actually disagree.

Also check for the same instruction stated in two rule files, and for a rule
restating something already in CLAUDE.md.

### 7. Verifiability — can a reader act on this?

Instructions must be concrete enough to check. Prefer "run `npm test` before
committing" over "test your changes"; "use 2-space indentation" over "format
code properly". Vague guidance costs tokens and changes nothing.

The same test catches the other way an instruction becomes unactionable: a rule
written straight out of the session that motivated it keeps that session's
context. "Use the wrapper we added", "as discussed above", a bare commit or
date, an internal name never glossed, a host or repo that was one run's
particulars — each names nothing to a reader who was not there, and a rule is
read cold on every matching edit forever after. The analyser flags the
phrasings; the unglossed name and the one-repo assumption only show up on
reading. This is a rewrite, not a cut: keep the invariant, drop the pointer to
where it came from, and state the name — "Bellhop (the batch-import path)".

### 8. Placement — should this be a rule at all?

A rule earns its place by being an invariant across several files that no
single comment owns. Report anything that fails that test with where it goes
instead; if the destination is unclear, or the question is repo level versus
user level, `../../refs/knowledge-placement.md` has both tables. The two
failures worth naming explicitly:

- A hard prohibition in a path-scoped rule. Path-scoped rules vanish after
  `/compact` until a matching file is read again, so promote it to CLAUDE.md or
  enforce it in a hook.
- A rule restating what a code comment in its own `paths:` already says. Run
  `scripts/comment-inventory.py <repo> --rule <name> --overlap` rather than
  asserting you checked.

## Anti-Patterns to Flag

- ❌ Unscoped rule that only applies to part of the repo
- ❌ Architecture overview, directory tree or dependency list as a rule
- ❌ Hard prohibition living in a path-scoped rule
- ❌ Wording that only resolves inside the session the rule came from
- ❌ `paths` glob that matches no files, or braces that blow the expansion budget
- ❌ Frontmatter keys other than `paths` (silently ignored)
- ❌ Two rules with overlapping globs giving conflicting instructions
- ❌ Vague guidance that cannot be verified
- ❌ Content duplicated between a rule and CLAUDE.md
- ❌ A rule paragraph retelling a measurement or war story that a code comment
  at the enforcement point already carries in fuller form
- ❌ Narrative prose where a bullet would carry the same instruction
- ❌ A `paths` glob far broader than the rule's subject — scoped, but billing
  every unrelated edit in the directory
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

Its companion answers the other mechanical question — what the code already
says. It dumps the substantive comments from exactly the files a rule's `paths:`
charges it against, which is the comparison the dedup pass in step 3 needs:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/comment-inventory.py" <repo-root> --rules
python3 "${CLAUDE_SKILL_DIR}/scripts/comment-inventory.py" <repo-root> --rule <name>
python3 "${CLAUDE_SKILL_DIR}/scripts/comment-inventory.py" <repo-root> --rule <name> --overlap
```

`--overlap` ranks each rule bullet against those comments by shared rare
vocabulary, so a rule scoping 80+ files is still reviewable. It ranks *literal*
overlap: a high score can be two statements that merely share jargon, and a
duplicate worded differently scores zero. Use it to choose where to start
reading, never as the verdict.

Then do the parts that need reading:

1. Read every rule file, plus every CLAUDE.md that loads alongside them. The
   analyser counts lines; only you can judge what the lines say.
2. Apply the derivability test to every section — cut what the codebase already
   states.
3. Apply the density test to what survives — the dedup pass. Run
   `comment-inventory.py` for the rule and classify every claim in it:

   | Where the fact lives | What to do |
   |---|---|
   | In a code comment, anchored to one enforcement point | **Delete from the rule.** Name the class/member so the reader can find it. |
   | In a code comment *and* CLAUDE.md *and* a rule | Keep the shortest prohibition in one place; delete the other two. |
   | Spans several files, no single enforcement point | **Keep in the rule** — this is what rules are for. |
   | Nowhere | Add it as a code comment (the default home), not to the rule. |

   **Do not trust a miss.** A comment often states the fact in different words
   than the rule does, which is exactly what neither `rg` nor `--overlap` can
   see. Grep the concept, not the identifier, and read the surrounding block
   before calling anything absent.
4. Check every scoped rule's match count against the files it actually
   discusses. A glob far wider than the subject is the cheapest finding in the
   review to fix and usually the largest.
5. For each overlapping set the analyser found, decide whether the rules
   actually contradict each other or merely coexist.
6. Check verifiability, then placement against the table above.
7. Triage the hygiene hits. The analyser matches patterns, not meaning, so each
   one needs a call. A **live secret** is a finding — rules are committed and
   shared, so treat them as public within the organisation and keep only the
   variable name. A **service identifier** (Jira cloud ID, project key, site
   URL) is fine; those are the non-derivable facts rules exist to hold. An
   **absolute path** is a portability bug, not a security one — make it relative.
8. Write the review to the template below. Lead with the context budget.
   Quantify cuts in lines removed from the always-on total, and rescoping and
   density work in mean rule words per matching edit — those are the numbers
   the user feels. If a row is hard to place — a cut whose recovery you cannot
   name, a move that is really a deletion — see
   `references/writing-findings.md`.

```markdown
## Rule Review: {{PROJECT}}

### Context budget
- Always-on: {{N}} lines / ~{{T}} tok ({{K}} unscoped rules + {{M}} CLAUDE.md)
- Path-scoped: {{N}} lines across {{K}} rules
- Verdict against the 200-line target

### ✅ Working well
- [Rules that are correctly scoped, sharp, and non-derivable]

### ⚠️ Issues
- [Per finding: file, what, why it matters, spec violation vs. judgement call]

### 📋 Cut list
- [File → sections to remove | reason | **what brings the knowledge back**]

### 🔀 Moves
- [File → CLAUDE.md / skill / hook / add `paths`, with the reason]

### Metrics
- Rules reviewed: {{N}} ({{K}} unscoped, {{M}} scoped)
- Globs matching zero files: {{N}}
- Overlapping glob sets: {{N}}
- Conflicts found: {{N}}
- Hardcoded credentials: Yes/No (should be No)
- Absolute paths: Yes/No (should be No)
```

   Take the counts from the analyser rather than recounting by hand, so a second
   run is comparable to the first.

## Reference Documentation

- Which destination a fact belongs in, and what each costs:
  `../../refs/knowledge-placement.md`

- Rules, CLAUDE.md and loading order: https://code.claude.com/docs/en/memory
- What survives compaction: https://code.claude.com/docs/en/context-window
- Hooks, for constraints that must be enforced: https://code.claude.com/docs/en/hooks

Fetch the docs when a claim is load-bearing. Do not review from memory — the
rules feature is young and its behaviour has changed across releases.
