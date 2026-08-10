# Review Output Format

Read this at write-up time, once the skill directory has been inspected.
Follow the template unless the user asked for something else.

```markdown
## Skill Review: {{SKILL_NAME}}

### ✅ Strengths
- [List what follows best practices]

### ⚠️ Issues Found
- [List problems with severity, marking spec violation vs. preference]

### 📋 Recommendations
- [Specific actionable improvements]

### Metrics
- Description length: {{X}} chars (spec cap: 1,024; listing cap: 1,536) — note
  whether the length is buying trigger coverage, not whether it is short
- Content length: {{Y}} lines (limit: 500; preferred: 100-200)
- Supporting files reviewed: {{N}}
- YAML valid: Yes/No
- References resolve: Yes/No
- Hardcoded credentials: Yes/No (should be No)
- Uses relative paths: Yes/No (should be Yes)
```

## Notes on the sections

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

**Metrics** exist so a later run is comparable to this one. Measure them rather
than estimating: line counts from `wc -l`, description length from the
frontmatter, link status from an actual fetch. A metric that was guessed is
worse than one that was omitted, because it looks checked.
