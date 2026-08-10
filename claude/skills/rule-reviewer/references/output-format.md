# Review Output Format

Read this at write-up time, once the analyser has run and the rules have been
read. Follow the template unless the user asked for something else.

```markdown
## Rule Review: {{PROJECT}}

### Context budget
- Always-on: {{N}} lines ({{K}} unscoped rules + {{M}} CLAUDE.md)
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

## Notes on the sections

**Context budget** leads because it is the number the user feels every session.
State it before any individual finding, so each cut can be read as a fraction of
a total the reader already has in mind.

**Cut list** carries the recovery column for a reason: a cut is only safe when
the removed knowledge comes back through something that fires on its own. Fill
that cell for every row. A row you cannot fill is not a cut — move it to Issues
and describe it as "bloated but load-bearing", so the user can decide with the
cost visible.

**Moves** and **Cut list** are different claims. A move keeps the knowledge and
changes where it loads; a cut removes it. Do not use a move row to smuggle a
deletion, and in particular do not list `docs/` as a destination for anything
the rule needs to state itself.

**Issues** should mark each finding as a spec violation (mechanical, the rule
will silently misbehave) or a judgement call. Users act on those differently:
the first is a bug to fix, the second is a trade-off to weigh.

**Metrics** exist so a second run is comparable to the first. Take the counts
from the analyser's output rather than recounting by hand.
