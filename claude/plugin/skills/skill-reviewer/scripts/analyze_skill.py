#!/usr/bin/env python3
"""Mechanical half of a skill review: frontmatter, budgets, pointers, hygiene.

Everything here is countable, so computing it by hand invites arithmetic slips
and quietly differs between runs. The judgement half — whether the description
buys trigger coverage, whether the scope is coherent, whether a flagged string
is really a secret — is left to the reviewer.

The HYGIENE table and CHARS_PER_TOKEN below are duplicated in the other
reviewer's analyser rather than shared. That is deliberate:
bin/claude-export-skills zips one skill directory, so a module imported from
outside it does not travel and the exported skill breaks on upload. Keep the
two copies in step by hand when either changes.

Usage:
    python3 analyze_skill.py <skill-dir> [--json] [--check-links]
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Only these survive packaging for claude.ai / the Skills API. Anything else in
# the frontmatter makes upload fail with a hard error, so it matters even though
# Claude Code itself accepts it.
PACKAGING_SAFE = {
    "name", "description", "license", "compatibility", "metadata", "allowed-tools",
}

# Valid in Claude Code, but local-only.
CLAUDE_CODE_ONLY = {
    "when_to_use", "context", "agent", "model", "effort", "paths", "argument-hint",
    "arguments", "hooks", "disable-model-invocation", "user-invocable",
    "disallowed-tools",
}

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

HYGIENE = [
    # A bare number is never a credential, and excluding one is what keeps
    # CHARS_PER_TOKEN below from matching its own detector. A word boundary
    # would do it too, but at the cost of api_token and friends, which are the
    # spelling this is actually hunting.
    ("credential", re.compile(
        r"(password|api_key|apikey|secret|token)s?\s*[=:]\s*(?![\d.]+\b)\S", re.I)),
    ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._-]{8,}")),
    ("connection-string", re.compile(r"\b\w+://[^/\s]+:[^@\s]+@")),
    ("absolute-path", re.compile(r"(/Users/|/home/[a-z]|C:\\Users)")),
    ("dev-note", re.compile(r"\b(TODO|FIXME|changelog|validated on|last updated)\b", re.I)),
    # Language that only resolves inside the session that produced the file.
    # A skill or rule is read cold, months later, by someone who was not there:
    # "the wrapper we added" and "as discussed above" name nothing, and a commit
    # or date pins it to one incident. Needs triage -- a documented *example* of
    # the anti-pattern trips this too.
    ("session-residue", re.compile(
        r"\bwe\s+(added|wrote|found|fixed|changed|decided|discussed|tried|noticed|"
        r"created|removed|ran|chose|agreed)\b"
        r"|\byou\s+(asked|mentioned|said|reported|requested)\b"
        r"|\bas\s+(discussed|mentioned|noted|described)\s+(above|earlier|previously|before)\b"
        r"|\bearlier\s+in\s+(this|the)\s+(session|conversation)\b"
        r"|\bthe\s+(fix|change|bug|issue|problem)\s+(above|from\s+earlier)\b"
        r"|\b20\d{2}-\d{2}-\d{2}\b"
        r"|(?<![0-9a-z/])(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}(?![0-9a-z])", re.I)),
    # Not a defect by itself: using the variable for a runtime path is correct,
    # documenting its name ships an expanded absolute path. Needs triage.
    ("substitution-var", re.compile(r"CLAUDE_(SKILL_DIR|PROJECT_DIR|PLUGIN_ROOT)")),
]

JUNK = ("__pycache__", ".DS_Store", ".pytest_cache", "node_modules", ".ruff_cache")

# Calibrated against this repo's 70 markdown files with tiktoken cl100k_base:
# 4.25 chars/token, 5.3% mean absolute error, worst single file 35% high on
# dense code. Good enough to size a budget, not to bill against -- the point is
# whether a skill costs 300 tokens or 3,000, which this settles without making
# the analyser depend on a tokeniser it would have to install.
CHARS_PER_TOKEN = 4.25


def est_tokens(chars):
    return round(chars / CHARS_PER_TOKEN)


# "Read X" is a step that runs; "see X" is a pointer you follow in a case. Only
# the imperative can be eager, which keeps a paragraph of "for Y, see X"
# cross-references from counting against the body budget. The verb list is
# deliberately short: `open` and `load` matched "Agent Skills open standard" and
# "when a claim is load-bearing", and a budget that counts those is not trusted.
# Anchored to a clause start, so only a real imperative counts: "See X for the
# escape hatches to check" ends in the verb without ever telling anyone to open
# X, and an unanchored match read that as a mandatory 264-line load.
# The marker group is load-bearing: read_units makes a list item unit-initial,
# so without it the anchor could never reach the verb and `- Read x.md` scored
# as deferred while `1. Read x.md` scored as eager -- the numbered form only
# worked by accident of the `.` in "1.". A comma joins the lookbehind for the
# same reason ("Before reporting, read x.md").
EAGER_RE = re.compile(r"(?:^|(?<=[.;:!?,])\s)\s*(?:[-*+]|\d+[.)]|\#{1,6})?\s*"
                      r"(read|consult|check|apply)\b", re.I)

# A condition in front of the imperative defers it again. `should` and `where`
# are excluded for the same reason as `open`: "report each with the destination
# it should move to" and "Where each finding goes" are not conditions, and
# admitting them hid two reads that do happen on every run.
GUARD_RE = re.compile(r"\b(if|when|unless|only|optional|as needed|"
                      r"in case|for the cases|otherwise|in the rare)\b", re.I)


LIST_RE = re.compile(r"\s*([-*+]|\d+[.)])\s")


def read_units(text):
    """Blocks a pointer's guard and imperative can plausibly share.

    A blank-line paragraph, except that list items are split apart: joining a
    reference list into one unit lets any bullet's verb decide the verdict for
    every pointer in it.

    Whatever introduces the list is prepended to every item rather than
    standing alone, because that is where the condition lives -- "Only when the
    analyser reports a dead pointer:" over a numbered step. Emitting the two
    separately left the step looking unconditional and billed a plainly guarded
    read against the always-on total.

    The introduction is found in two places, and both are needed: text sitting
    directly above the first item, and the previous paragraph when it ends in a
    colon. Markdown puts a blank line before a list at least as often as not,
    and only the second case survives the blank-line split.
    """
    units, intro = [], ""
    for block in re.split(r"\n\s*\n", text):
        lines = block.splitlines()
        if not any(LIST_RE.match(ln) for ln in lines):
            flat = " ".join(block.split())
            units.append(flat)
            intro = flat if flat.endswith(":") else ""
            continue

        def emit(parts):
            units.append(" ".join(f"{intro} {' '.join(parts)}".split()))

        lead, cur = [], []
        for ln in lines:
            if LIST_RE.match(ln) and cur:
                if not lead and not LIST_RE.match(cur[0]):
                    lead = cur
                else:
                    emit(lead + cur)
                cur = []
            cur.append(ln)
        if cur:
            emit(lead + cur)
        intro = ""
    return [u for u in units if u]


# Side effects the author probably wants gated behind explicit invocation.
# Base and gerund forms only: a past participle is usually describing something
# ("Anthropic's published spec"), not promising to do it.
SIDE_EFFECT_RE = re.compile(
    r"\b(deploy|publish|commit|push|merge|send|delete|destroy|provision|migrate|"
    r"upload|notify)(?:e?s|ing)?\b", re.I)


def parse_frontmatter(text):
    """Minimal top-level YAML reader. Avoids a pyyaml dependency, which is not
    guaranteed present and would make the script fail where it is most needed."""
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, ""
    body = text[m.end():]
    fields, key = {}, None
    for line in m.group(1).splitlines():
        kv = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if kv:
            key = kv.group(1)
            fields[key] = kv.group(2).strip()
        elif key and line.strip():
            fields[key] = (fields[key] + " " + line.strip()).strip()
    for k, v in fields.items():
        if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
            fields[k] = v[1:-1]
    return fields, body


def analyze(skill_dir):
    d = Path(skill_dir).resolve()
    md = d / "SKILL.md"
    if not md.is_file():
        raise SystemExit(f"error: no SKILL.md in {d}")

    text = md.read_text(encoding="utf-8", errors="replace")
    fields, body = parse_frontmatter(text)
    r = {"skill_dir": str(d), "dir_name": d.name, "problems": [], "notes": [],
         "hygiene": [], "files": [], "links": []}

    if fields is None:
        r["problems"].append(("spec", "SKILL.md has no YAML frontmatter"))
        fields, body = {}, text

    r["frontmatter"] = dict(fields)

    # --- name -------------------------------------------------------------
    name = fields.get("name")
    if not name:
        r["problems"].append(("spec", "missing `name` (required by the spec; "
                                      "Claude Code tolerates it, packaging does not)"))
    else:
        if not NAME_RE.match(name):
            r["problems"].append(("spec", f"`name` {name!r} must be lowercase "
                                          "alphanumeric and hyphens, no leading/"
                                          "trailing/double hyphen"))
        if not 1 <= len(name) <= 64:
            r["problems"].append(("spec", f"`name` is {len(name)} chars (must be 1-64)"))
        if name != d.name:
            r["problems"].append(("spec", f"`name` {name!r} != directory {d.name!r} "
                                          "— breaks portability"))

    # --- description ------------------------------------------------------
    desc = fields.get("description", "")
    r["description_chars"] = len(desc)
    if not desc:
        r["problems"].append(("spec", "missing `description` (the primary trigger)"))
    elif len(desc) > 1024:
        r["problems"].append(("spec", f"`description` is {len(desc)} chars (spec cap 1,024)"))
    listing = len(desc) + len(fields.get("when_to_use", ""))
    r["listing_chars"] = listing
    if listing > 1536:
        r["problems"].append(("spec", f"description + when_to_use is {listing} chars; "
                                      "Claude Code truncates the listing at 1,536"))

    # --- frontmatter keys -------------------------------------------------
    keys = set(fields)
    r["unpackageable_keys"] = sorted(keys - PACKAGING_SAFE)
    r["unknown_keys"] = sorted(keys - PACKAGING_SAFE - CLAUDE_CODE_ONLY)
    for k in r["unknown_keys"]:
        r["problems"].append(("check", f"frontmatter key {k!r} is not a known field "
                                       "— typo, or inert"))

    # --- invocation control ----------------------------------------------
    if SIDE_EFFECT_RE.search(desc) and fields.get("disable-model-invocation") != "true":
        r["notes"].append("description mentions side effects; consider "
                          "`disable-model-invocation: true` so only the user triggers it")

    # --- body budget ------------------------------------------------------
    # The 500-line ceiling is on SKILL.md itself; the 100-200 band is on what
    # actually loads, computed once the pointers are resolved below.
    total = len(text.splitlines())
    r["lines"] = total
    if total > 500:
        r["problems"].append(("spec", f"SKILL.md is {total} lines (official limit 500)"))

    # --- writing-style signals -------------------------------------------
    r["allcaps_imperatives"] = len(re.findall(r"\b(MUST|NEVER|ALWAYS)\b", body))
    if r["allcaps_imperatives"]:
        r["notes"].append(f"{r['allcaps_imperatives']} all-caps MUST/NEVER/ALWAYS "
                          "— prefer explaining why; rigid imperatives are a yellow flag")

    # --- bundled files, pointers, junk ------------------------------------
    for f in sorted(d.rglob("*")):
        if not f.is_file():
            continue
        rel = str(f.relative_to(d))
        if any(j in f.parts for j in JUNK) or f.name in JUNK:
            r["problems"].append(("check", f"build artifact should not ship: {rel}"))
            continue
        content = f.read_text(encoding="utf-8", errors="replace")
        r["files"].append({"path": rel, "lines": len(content.splitlines()),
                           "chars": len(content)})

    # Consume any leading path before the keyword directory, so a pointer into
    # *another* skill is seen whole. Matching the bare tail instead makes
    # `~/.claude/skills/other/scripts/x.py` read as this skill's `scripts/x.py`
    # and reports a working absolute path as dead — a spec-level problem for a
    # file that is right there.
    # The skill-dir variable *is* the skill root, so drop it before scanning:
    # left in, its trailing slash reads as an absolute path and every bundled
    # file referenced the documented way is reported missing.
    scan = re.sub(r"\$\{?CLAUDE_SKILL_DIR\}?/", "", text)
    # A URL is not a file. `[~\w./-]*` does not cross `:` but does cross `/`,
    # so a deep link such as .../skills/tree/main/x/scripts/helper.py yielded
    # the token `//github.com/.../scripts/helper.py`, which leads with `/`,
    # reads as an absolute path, resolves nowhere, and was then reported as a
    # spec violation -- the analyser's loudest verdict, on a working link.
    scan = re.sub(r"https?://\S+", " ", scan)
    # `<skill-dir>/scripts/x` is the docs' way of writing the skill root. The
    # placeholder is not part of the path, and leaving it in made the match
    # start at `/scripts`, i.e. absolute, i.e. dead.
    scan = re.sub(r"<[^<>\s]+>/", "", scan)
    referenced, external = set(), set()
    # `refs` is listed as well as `references`: the shared library outside the
    # skill lives at `../../refs/`, and leaving it out made every pointer into
    # it invisible -- neither validated as a link nor counted when read.
    # Alternation is left-biased, so `references` still wins where both fit.
    # The prefix is whole path segments rather than any run of path characters:
    # the loose form let `my-scripts/x.md` match from the word start, turning an
    # unrelated directory into a dead pointer into this skill.
    for tok in re.findall(r"(?<![\w.-])(?:[~\w.-]+/)*"
                          r"(?:references|refs|scripts|assets|examples)/[\w./-]+", scan):
        if tok.startswith(("~", "/")):
            external.add(tok)
        else:
            referenced.add(tok[2:] if tok.startswith("./") else tok)

    r["pointers"] = ([{"path": p, "exists": (d / p).is_file()} for p in sorted(referenced)]
                     + [{"path": p, "exists": Path(p).expanduser().is_file()}
                        for p in sorted(external)])
    for p in r["pointers"]:
        if not p["exists"]:
            r["problems"].append(("spec", f"SKILL.md points at {p['path']} which does not exist"))

    # A bundled .md the body reads on every run costs exactly what the same
    # prose would cost inside SKILL.md, so it counts against the band. Moving
    # text into references/ defers nothing unless the read is guarded by a
    # condition -- an unguarded "Read references/x.md" step buys a tool call
    # and no tokens back. One unguarded mention is enough to make it eager.
    units = read_units(text)
    by_path = {f["path"]: f for f in r["files"]}
    r["eager"], r["always_on"] = [], total
    load_chars = len(text)
    # A ref outside the skill directory is billed exactly like a bundled one
    # once the body says to read it, so both are measured the same way. Only
    # the size lookup differs: bundled files are already counted above.
    # Keyed by resolved path, not by spelling: a body that writes both
    # `../../refs/x.md` and `~/.claude/refs/x.md` names one file that loads
    # once, and summing the two spellings billed it twice.
    seen = set()
    for ptr in sorted(referenced) + sorted(external):
        if not ptr.endswith(".md"):
            continue
        if ptr in by_path:
            size = (by_path[ptr]["lines"], by_path[ptr]["chars"])
            key = (d / ptr).resolve()
        else:
            f = Path(ptr).expanduser()
            if not f.is_absolute():
                f = (d / ptr).resolve()
            if not f.is_file():
                continue
            key = f.resolve()
            c = f.read_text(encoding="utf-8", errors="replace")
            size = (len(c.splitlines()), len(c))
        if key in seen:
            continue
        windows = [u for u in units if ptr in u]
        if any(EAGER_RE.search(w) and not GUARD_RE.search(w) for w in windows):
            seen.add(key)
            r["always_on"] += size[0]
            load_chars += size[1]
            r["eager"].append({"path": ptr, "lines": size[0]})

    # Two different bills. The listing entry is charged in every session of
    # every project whether or not the skill is ever used; the body is charged
    # only when it activates. A fat description is the expensive one.
    r["tokens_listed"] = est_tokens(r["listing_chars"])
    r["tokens_load"] = est_tokens(load_chars)
    if r["always_on"] > 200:
        detail = ""
        if r["eager"]:
            parts = " + ".join(f"{e['lines']} {e['path']}" for e in r["eager"])
            detail = f" ({total} SKILL.md + {parts}, read on every run)"
        r["notes"].append(f"always-on body is {r['always_on']} lines; preferred "
                          f"band is 100-200{detail}")

    bundled = {f["path"] for f in r["files"]} - {"SKILL.md"}
    for orphan in sorted(bundled - referenced):
        r["notes"].append(f"{orphan} is bundled but never referenced from SKILL.md")

    # --- hygiene across the whole directory -------------------------------
    for f in r["files"]:
        content = (d / f["path"]).read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(content.splitlines(), 1):
            for label, rx in HYGIENE:
                if rx.search(line):
                    r["hygiene"].append({"file": f["path"], "line": i, "kind": label,
                                         "text": line.strip()[:100]})

    # Backticks terminate a URL: skills routinely write links inside code spans,
    # and swallowing the closing backtick turns every one into a fake dead link.
    raw = re.findall(r"https?://[^\s)>\]\"'`]+", text)
    links = set()
    for url in raw:
        url = url.rstrip(".,;:")  # trailing sentence punctuation, not part of the URL
        if "<" in url or "{" in url:
            continue  # a template like .../create/{REQUEST_TYPE_ID}, not a link to fetch
        links.add(url)
    r["links"] = sorted(links)
    return r


def check_links(links):
    import urllib.error
    import urllib.request
    out = []
    for url in links:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "skill-reviewer"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                out.append({"url": url, "status": resp.status})
        except urllib.error.HTTPError as e:
            out.append({"url": url, "status": e.code})
        except Exception as e:
            out.append({"url": url, "status": f"error: {type(e).__name__}"})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skill_dir")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--check-links", action="store_true",
                    help="fetch every URL (network); otherwise they are only listed")
    args = ap.parse_args()

    r = analyze(args.skill_dir)
    if args.check_links:
        r["link_status"] = check_links(r["links"])

    if args.json:
        print(json.dumps(r, indent=2))
        return 0

    budget = f"{r['lines']} lines"
    if r["always_on"] != r["lines"]:
        budget = f"{r['lines']} lines, {r['always_on']} always-on"
    print(f"SKILL: {r['dir_name']}  ({budget}, "
          f"description {r['description_chars']} chars)")
    print(f"  ~{r['tokens_listed']:,} tok in every session (listing entry)  ·  "
          f"~{r['tokens_load']:,} tok on activation (body"
          f"{' + refs read every run' if r['eager'] else ''})\n")

    if r["problems"]:
        print("PROBLEMS")
        for kind, msg in r["problems"]:
            print(f"  [{kind}] {msg}")
    else:
        print("PROBLEMS  none")

    if r["notes"]:
        print("\nWORTH A LOOK (preferences, not violations)")
        for n in r["notes"]:
            print(f"  - {n}")

    if r["unpackageable_keys"]:
        print(f"\nBLOCKS PACKAGING for claude.ai: {', '.join(r['unpackageable_keys'])}")

    print("\nFILES")
    for f in r["files"]:
        print(f"  {f['lines']:>5}  {f['path']}")

    if r["pointers"]:
        print("\nINTERNAL POINTERS")
        for p in r["pointers"]:
            print(f"  {'OK  ' if p['exists'] else 'DEAD'}  {p['path']}")

    if r["hygiene"]:
        print("\nHYGIENE (patterns, not verdicts — triage each)")
        for h in r["hygiene"]:
            print(f"  {h['file']}:{h['line']} [{h['kind']}] {h['text']}")

    print("\nLINKS")
    for item in r.get("link_status", [{"url": u, "status": "not checked"} for u in r["links"]]):
        print(f"  {item['status']}  {item['url']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
