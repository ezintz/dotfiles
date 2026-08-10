---
name: skill-reviewer
description: Reviews a Claude skill against Anthropic's published spec and authoring guidance. Use when asked to review, validate, or check a skill.
allowed-tools: Read Grep WebFetch Bash
---

# Skill Reviewer

Reviews skills against the Agent Skills spec and the Claude Code skills
documentation. Distinguishes hard requirements from style preferences — say which
is which in every finding.

## When to Use

- User asks to review a skill
- User wants to validate skill structure
- User asks if skill follows best practices
- After creating/modifying a skill

## Review Criteria

### 1. YAML Frontmatter

The spec requires `name` and `description`; every other field is optional. Claude
Code is laxer — it treats all fields as optional and only recommends
`description` — so a skill missing `name` still works locally. Review against the
spec by default and note the laxer local behaviour; only waive `name` when the
skill is explicitly local-only. Never report any other missing field as a violation.

**`name`** — required by the spec, with hard rules:
- 1-64 characters
- Lowercase alphanumeric (`a-z`, `0-9`) and hyphens only
- Must not start or end with a hyphen, and no consecutive hyphens (`--`)
- **Must match the parent directory name**
- Claude Code note: the *command* you type comes from the directory name anyway
  (only plugin skills take it from `name`), so a mismatch breaks portability
  rather than local invocation

**`description`** — required by the spec:
- Explains WHAT the skill does and WHEN to activate it
- Functional, not marketing tone
- Hard limit: 1,024 characters (spec). Separately, Claude Code truncates
  `description` + `when_to_use` at 1,536 characters in the skill listing, so put
  the key use case first.
- Length is earned by trigger coverage, not by prose. There is no good character
  target. Claude under-triggers skills far more often than it over-triggers them,
  so concrete trigger phrases, file types, tool names and boundaries against
  competing skills are worth their characters even when they push a description
  past 500. Anthropic's own `skill-creator` deliberately recommends writing
  descriptions that lean pushy for this reason.
- Judge each clause by one question: would removing it change an activation
  decision? Clauses that restate the skill's purpose in different words, or list
  capabilities no user phrase would match, are the ones to cut — a 900-character
  description of well-chosen triggers is healthier than a 200-character one that
  only says what the skill does.

**`allowed-tools` (optional):**
- Pre-approves tools for the invoking turn; it does not restrict the tool pool.
  Use `disallowed-tools` to actually remove a tool.
- Should cover what the skill's own steps require

**Invocation control:**
- A skill with side effects (deploy, commit, send a message, mutate a cluster)
  should set `disable-model-invocation: true` so only the user can trigger it
- Background knowledge with no meaningful command should set `user-invocable: false`

**Other fields** worth checking when relevant: `when_to_use`, `context: fork`,
`agent`, `model`, `effort`, `paths`, `argument-hint`, `arguments`, `hooks`.
Note that only `name`, `description`, `license`, `compatibility`, `metadata`, and
`allowed-tools` survive packaging for claude.ai or the Skills API — any other
field makes upload fail with a hard error.

### 2. Content Philosophy

**Focused scope:**
- Single, well-defined purpose
- Not trying to cover too much
- Specific workflow or task

**Concise instructions:**
- Official limit: keep `SKILL.md` under 500 lines
- Preference: 100-200 lines; question anything past that
- Skill content stays in context across turns, so every line is a recurring cost
- Focus on "what Claude needs to execute"; move reference material to a separate
  file in the skill directory

**Progressive disclosure:**
- Claude sees name + description first
- Decides relevance before loading full content
- Only loads what's needed, when needed

### 3. Structure Best Practices

**Clear sections:**
- Variables/inputs clearly defined
- Step-by-step workflow if procedural; evaluate Claude Code workflow usage
- Examples when helpful (not required)

**References over duplication:**
- Link to comprehensive docs
- Don't repeat what exists elsewhere
- Keep DRY (Don't Repeat Yourself)

**Operational focus:**
- Instructions Claude follows
- Not meta-commentary about development
- Remove version history, changelog, timestamps

### 4. Anti-Patterns to Flag

- ❌ Generic/vague description (doesn't explain when to use)
- ❌ Description padded with restated purpose or unmatched capability lists —
  length itself is not the defect, absence of trigger value is
- ❌ Body over 500 lines (official limit), or past ~200 without justification
- ❌ Side-effecting skill with no `disable-model-invocation: true`
- ❌ Frontmatter field that blocks packaging, if the skill is meant for claude.ai
- ❌ Duplicates existing docs (should reference instead)
- ❌ Development notes in content (timestamps, "validated on...", changelog)
- ❌ Mixed language without clear reason
- ❌ Overly complex (trying to do too much)
- ❌ Hardcoded credentials (passwords, API keys, tokens, database credentials)
- ❌ Sensitive data in examples (should use placeholders or .env variables)
- ❌ Absolute paths in examples (/home/user/..., C:\Users\...)
- ❌ Substitution variables spelled out literally in the body — they expand on load
- ❌ Platform-specific paths (Windows-only or Unix-only)
- ❌ Dead links in the reference section — resolve them, don't assume

## Reference Documentation

- Claude Code frontmatter and behavior: https://code.claude.com/docs/en/skills
- Agent Skills open standard: https://agentskills.io/specification
- Spec, template, and examples: https://github.com/anthropics/skills
  (`spec/`, `template/`, `skills/`)

Fetch the docs when a claim is load-bearing. Do not review from memory of the
spec — it changes.

## Process

Start with the bundled analyser. It settles everything countable — frontmatter
validity, name/directory agreement, description and body budgets, packaging
safety, bundled files, internal pointers, hygiene patterns, link status — so
your attention goes to the judgement it cannot make. Counting these by hand
invites arithmetic slips and gives a different answer each run.

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/analyze_skill.py" <skill-dir>
python3 "${CLAUDE_SKILL_DIR}/scripts/analyze_skill.py" <skill-dir> --check-links
python3 "${CLAUDE_SKILL_DIR}/scripts/analyze_skill.py" <skill-dir> --json
```

It separates `PROBLEMS` (spec violations and dead pointers) from `WORTH A LOOK`
(preferences), which is the same split the review output needs. Pass
`--check-links` when the reference section matters; it fetches each URL.

Then do the parts that need reading:

1. Read `SKILL.md` in full, plus every bundled file the analyser listed. It
   counts lines; only you can judge what they say.
2. Judge the description by trigger coverage, not length: would removing a
   clause change an activation decision? The analyser reports the character
   count and the caps, not whether the characters earn their place.
3. Assess scope and structure — one clear purpose, reference material pushed
   out of the always-loaded body.
4. Triage the hygiene hits. The analyser matches patterns, not meaning: a
   documented example of a credential pattern is not a credential, and a
   substitution variable used for a runtime path is correct while one written
   out to document its own name is the anti-pattern.
5. Identify anti-patterns from the list above that no regex can see.
6. Read `references/output-format.md` and write the review to that template,
   marking each finding as a spec violation or a preference.

## Triaging the hygiene hits

The analyser matches patterns across the whole directory. Deciding what each one
means is the review:

- A **live credential** is a finding: move the value to `.env`, keep only the
  variable name in the skill, and check `.env` is gitignored. A documented
  *example* of a credential pattern is not a credential — this skill trips its
  own regexes for exactly that reason.
- An **absolute path** is a portability bug. Prefer a relative path, or `~/` for
  home. For paths that must resolve at runtime, use the CLAUDE_SKILL_DIR
  variable (files bundled with the skill) or CLAUDE_PROJECT_DIR (the project
  root), written in dollar-brace form.
- A **substitution variable** needs the sharpest call. Using one for a runtime
  path is correct. Writing one out to document its own name is the anti-pattern:
  Claude Code expands these inside skill bodies, so the skill ships an expanded
  absolute path to whoever loads it, and backticks do not prevent it. Those two
  names are deliberately written above without the dollar sign for that reason.
- **Platform-specific content** — Windows-only paths, Unix-only commands — is
  not pattern-matchable; check it while reading.
