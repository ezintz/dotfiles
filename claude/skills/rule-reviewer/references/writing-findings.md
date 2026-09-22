# Writing the findings

The template lives in `SKILL.md`, because it is followed on every run. This file
is for the rows that are hard to place rather than routine.

**Cut list carries a recovery column for a reason.** A cut is only safe when the
removed knowledge comes back through something that fires on its own. Fill that
cell for every row. A row you cannot fill is not a cut — move it to Issues and
describe it as "bloated but load-bearing", so the user can decide with the cost
visible.

**Moves and cuts are different claims.** A move keeps the knowledge and changes
where it loads; a cut removes it. Do not use a move row to smuggle a deletion,
and in particular do not list `docs/` as a destination for anything the rule
needs to state itself — nothing triggers that read.

**Mark each issue** as a spec violation (mechanical: the rule will silently
misbehave) or a judgement call. Users act on those differently — the first is a
bug to fix, the second is a trade-off to weigh.
