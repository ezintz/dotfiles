# Writing the findings

The template lives in `SKILL.md`, because it is followed on every run. This file
is for the calls that are hard rather than routine.

**Mark every issue** as a spec violation or a preference. The spec is a small
document and most of what reviewers flag lives outside it; presenting taste as a
requirement is the fastest way for a review to lose its authority. A missing
`name` and a 260-line body are not the same kind of problem.

**Strengths are not filler.** They tell the author which parts to leave alone
during the next revision. A review that only lists faults invites rewrites of
things that were already working.

**Recommendations should be applicable without further questions** — name the
file, the section and the replacement. "Tighten the description" is not
actionable; "add the file extensions the skill handles, since a user asking
about `.docx` currently matches nothing" is.
