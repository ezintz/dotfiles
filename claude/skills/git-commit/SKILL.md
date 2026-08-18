---
name: git-commit
description: End-of-work checklist — reviews the session for durable lessons (skill gaps, knowledge, automation ideas), writes them to CLAUDE.md/rules, then commits everything together. Use when the user invokes /git-commit, or signals the work itself is finished: "wrap things up", "end session", "ship it", "we're done", "open a PR/MR". NOT for a routine commit inside ongoing work — "commit this", "commit and push", "save that" — which is plain git with no review.
---

# Git commit

At the end of a piece of work: review the session for durable lessons, write
them into the right file, then commit everything together. A commit asked for
mid-work is Phase 3 alone — see below.

## When this runs

The review is the substance of this skill and it is not free: it reads the
session back and writes files. It belongs at the end of the *work*, not at
every commit.

- **Run it** for `/git-commit`, or when the user signals the work is done —
  wrap up, end session, ship it, we're done, open a PR/MR.
- **Skip to Phase 3** for a routine commit mid-work. Commit what was asked and
  stop: no review, no learning files, no mention of the phases.
- **When it is unclear, commit first** and offer the review in one line
  afterwards. Never hold a commit the user asked for behind a review they
  did not.

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

The bar is "a competent engineer who knows this stack would still get this
wrong." Restructuring work is especially prone to producing a finding that
merely narrates the restructuring — the new layout is the artifact, and it
does not need a paragraph telling the next session to respect it.

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

Present findings in this format, one line of context above each:

```
✅ Skill gap: Cost estimates were wrong multiple times
→ [CLAUDE.md] Added token counting reference table

✅ Knowledge: Worker crashes on 429/400 instead of retrying
→ [Rules] Added error-handling rules for worker

✅ Automation: Checking service health after deploy is manual
→ [Skill] Created post-deploy health check skill spec
```

## How to write it

Bullets, not prose. A rule is re-read on every matching edit, so the narrative
version of a lesson is billed again and again for the one instruction inside it.

- **One bullet per finding, phrased as an instruction** — do X, never Y.
- **Lead with the rule.** If a reason is needed it rides the same bullet after
  an em dash; it does not get a paragraph of its own.
- **Two lines each, maximum.** A finding that will not compress is either two
  findings or belongs in the code instead.
- **Evidence goes in the code, not the rule.** Measurements, the bug that forced
  the choice, the silent-failure mode — put them in a comment at the enforcement
  point. The rule states the constraint and points there.
- **Never retell what another file already says.** Read the destination and the
  relevant code first; if the fact is already at its enforcement point, the rule
  gets a pointer, not a second copy.
- **Scope `paths:` to the files the rule can actually change a decision about.**
  `src/**`, or a whole project directory, bills every unrelated edit for it.
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

Then show what was actually written, not just where it went. For every file
touched, print the path and the full text that was added or changed —
verbatim, in a fenced block. Anything saved to memory gets the same
treatment: memory is invisible to the user and shapes later sessions, so
never report it as "saved a preference to memory" and leave it at that.
Quote it in full so it can be corrected or thrown out on the spot.

## Phase 3: Commit

Commit the session's changes together with any learning files written in
Phase 2. Read the last ~10 subject lines and match them — a repo's convention
is its own and is rarely the generic one. Stage explicitly by path
— never `git add -A` or `git commit -a` — so nothing unrelated rides along.
`CLAUDE.local.md` is never staged or committed.
