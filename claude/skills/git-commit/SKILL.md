---
name: git-commit
description: End-of-work checklist — reviews the session for durable lessons (skill gaps, knowledge, automation ideas), writes them to CLAUDE.md/rules, then commits everything together. Use when the user invokes /git-commit, or signals the work itself is finished: "wrap things up", "end session", "ship it", "we're done", "open a PR/MR". NOT for a routine commit inside ongoing work — "commit this", "commit and push", "save that" — which is plain git with no review.
---

When it is unclear whether the work is finished, commit first and offer the
review afterwards — never hold a requested commit behind a review the user
didn't ask for.

## Phase 1: Review

Launch an agent using the `Sonnet 5` model at `medium` effort and look for
durable, reusable lessons from this session. Hand it the session's own
history as the input to reason over — it shouldn't re-explore the repo or
reconstruct context it was already given. Reading a destination file to
check for an existing entry is fine; re-investigating the code is not.

- Corrections or preferences the user stated
- Things Claude got wrong, retried, or should have known already
- Manual steps the user had to request that should've been automatic
- Repetitive work a script or hook could replace
- Existing entries this session proved wrong, stale, or wrongly scoped

Drop anything that won't recur (a specific bug, a one-off command run once).
If nothing durable came up, say so and skip to Phase 3 — don't manufacture
findings.

**Drop anything Claude already knows.** A finding must be a fact about
*this* codebase, *this* toolchain or *this* user that a fresh session would
otherwise rediscover the hard way. It is not a finding if it restates:

- how Claude Code itself works
- general engineering practice
- a convention already visible in the repo's own layout or config;
- what the code plainly says, which is exactly what a rule must *not* be.

The bar is: "a competent engineer who knows this stack would still get this
wrong."

For each finding, record what happened, what should happen instead (as an
instruction Claude could follow), and where it goes.

**Verify a finding before writing it.** Anything asserting a fact about the
codebase — a path, a glob, a constraint, a number — gets checked against the
codebase first: read the file, run the glob, grep for the symbol. Session
memory is a lead, not evidence, and a rule built on a misremembered detail is
worse than no rule, because the next session believes it. What cannot be
checked cheaply is presented, not written.

**A session that moved, split or renamed things has almost certainly
invalidated an existing entry.** Look for pointers that no longer resolve: a
rule naming a file that moved, a cross-reference to a section that now lives
elsewhere, a `paths:` glob that stopped matching. Repairing those is a finding,
and it is the kind only this session is placed to notice.

Repo level and user level have the same structure, so the only question is
reach: does this apply just to the repo you're in, or to every repo you
work in? Tool-level knowledge (Kubernetes, Gateway API, ArgoCD, Docker,
crictl, …) is the usual reason to go user level.

| Finding | This repo | Every repo |
| --- | --- | --- |
| Convention needed in every session | `./CLAUDE.md` | `~/.claude/CLAUDE.md` |
| Rule scoped to a file type, library, or directory | `./.claude/rules/<name>.md` | `~/.claude/rules/<name>.md` |
| Reference detail too long to inline | `./.claude/refs/<name>.md` | `~/.claude/refs/<name>.md` |
| Recurring procedure worth a skill | `./.claude/skills/<name>/SKILL.md` | `~/.claude/skills/<name>/SKILL.md` |
| Mechanical check worth a hook | `./.claude/hooks/<name>.sh` | `~/.claude/hooks/<name>.sh` |

Rules take `paths:` and a one-line `description:` frontmatter; refs are
linked from the rule or CLAUDE.md entry that needs them. Skills and hooks
run on their own once in place, so write the spec and let the user decide
rather than creating them outright. That caution is about *new* automation:
fixing a rule, skill or hook that already exists and got something wrong is an
ordinary edit — make it.

Two things that sit outside the table: personal or in-flight context goes
in `./CLAUDE.local.md` and is never committed, and a lesson about the
user's preferences or working style isn't a file at all — save it via the
memory system.

## How to write it

- **One bullet per finding, phrased as an instruction** — do X, never Y.
- **Lead with the rule.** If a reason is needed it rides the same bullet after
  an em dash; it does not get a paragraph of its own.
- **Two lines each, maximum.** A finding that will not compress is either two
  findings or belongs in the code instead.
- **Prefer a bullet on an existing rule** over a new file.

## Phase 2: Save learnings

Launch an agent using the `Sonnet 5` model at `medium` effort and write
each finding to its destination without asking per-item approval, then
summarize what went where. Search first — the destination file *and* the code
it concerns: update an existing entry rather than adding a duplicate, change
nothing if it is already covered, and when the fact already sits in a comment
at its enforcement point, write the pointer rather than a second copy.

After writing a rule, confirm its `paths:` globs match real files. A glob that
matches nothing is a rule that never loads, and nothing reports it.

Then check the second-copy claim rather than asserting it — for each rule
touched this session, not the whole directory, which is `rule-reviewer`'s job:

```bash
python3 ~/.claude/skills/rule-reviewer/scripts/comment-inventory.py \
    --rule <name> --overlap
```

A user-level rule needs its full path — `--rule ~/.claude/rules/<name>.md`;
the bare name only resolves against the current repo's `.claude/rules/`.

It ranks the new text against the comments in exactly the files that rule is
charged against. Where the enforcement point already carries the fact, replace
what was written with a one-line invariant and a pointer to it.

Present findings and written changes in this format, one line of context above
each. **Every finding opens with its reach** — `Global` for anything under
`~/.claude`, `Project` for anything in the repo — so scope is readable at a
glance instead of inferred from a `~` or a `.` in the path below it. Never
leave it off to mean global.

**Pick the emoji for the finding itself**, never a fixed one — a shell for a
shell trap, a stethoscope for a health check, a retry arrow for backoff. A
column that reads the same on every line carries no information:

```markdown
🐚 Global · Knowledge => `unsetopt CLOBBER` makes `>` fail instead of overwriting
[~/.claude/CLAUDE.md] Added the redirection trap to the shell section

🛡️ Project · Knowledge => The dispatcher globs `*.guard`, so `_` files are helpers
[./CLAUDE.md] Documented why a profile filename cannot start with `_`

🧮 Global · Skill gap => Cost estimates were wrong every time they were asked for
[~/.claude/skills/<skill>/SKILL.md] Added the token counting reference table

🩺 Project · Automation => Post-deploy health checks were run by hand
[./.claude/skills/<skill>/SKILL.md] Created the health check skill spec

🔁 Project · Rule gap => Worker crashes on 429/400 instead of backing off
[./.claude/rules/<rule-file>] Added the retry policy and scoped its `paths:`
```

Order them Global first, then Project. A session that wrote to both is the one
where reach is easiest to get wrong, and grouping makes a misfiled finding
visible before it is committed.

**Make every write with `Edit` or `Write`, never with a Bash heredoc, `sed` or
a script.** Only that tool result renders as a diff on every host. A fenced
`diff` block in the reply is coloured in the terminal but flat in the panel,
and `git diff --color` reaches the transcript rather than the user. A change
written through Bash renders nowhere at all, so it lands unreviewed.

Write each file as its own tool call, so its diff lands next to the finding it
belongs to rather than in one block at the end.

Memory writes have no diff. Quote what was saved in full — memory is
invisible to the user and shapes later sessions.

## Phase 3: Commit

Commit the session's changes together with any learning files written in
Phase 2. Read the last ~10 subject lines and match them — a repo's convention
is its own and is rarely the generic one. Stage explicitly by path
— never `git add -A` or `git commit -a` — so nothing unrelated rides along.
`CLAUDE.local.md` is never staged or committed.
