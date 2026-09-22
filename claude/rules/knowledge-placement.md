---
paths: ["**/CLAUDE.md", "**/CLAUDE.local.md", "**/.claude/rules/**"]
---

Every fact gets exactly one home in loaded context; a second copy is billed on
every edit that loads both. A code comment is the default home — before writing
a fact into this file, check whether a comment already carries it.

`~/.claude/refs/knowledge-placement.md` has the destinations, what each costs,
and the repo-versus-user reach table.

Skill bodies are deliberately out of scope here: `skill-reviewer` and
`rule-reviewer` link the same ref from their own procedures, so a rule firing on
every edit under `.claude/skills/` would only repeat a pointer already given.
