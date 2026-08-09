---
name: git-commit
description: Use when the user finishes an implementation and says "commit", "push", "ship it", "wrap things up", "end session", "open a PR/MR", or invokes /git-commit — runs an end-of-work checklist to capture durable lessons (skill gaps, knowledge, automation ideas), then commit.
---

# Git commit

Before committing, review the session for durable lessons, write them into
the right file, then commit everything together.

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

Drop anything that won't recur (a specific bug, a one-off command run once).
If nothing durable came up, say so and skip to Phase 3 — don't manufacture
findings.

For each finding, record what happened, what should happen instead (as an
instruction Claude could follow), and where it goes.

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
rather than creating them outright.

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

## Phase 2: Save learnings

Launch an agent using the `Sonnet 5` model at `medium` effort and write
each finding to its destination without asking per-item approval, then
summarize what went where. Search the destination first: update an existing
entry instead of adding a duplicate, and change nothing if it already covers
the finding.

## Phase 3: Commit

Commit the session's changes together with any learning files written in
Phase 2, using the repository's commit convention. Stage explicitly by path
— never `git add -A` or `git commit -a` — so nothing unrelated rides along.
`CLAUDE.local.md` is never staged or committed.
