#!/usr/bin/env python3
"""Mechanical half of a skill review: frontmatter, budgets, pointers, hygiene.

Everything here is countable, so computing it by hand invites arithmetic slips
and quietly differs between runs. The judgement half — whether the description
buys trigger coverage, whether the scope is coherent, whether a flagged string
is really a secret — is left to the reviewer.

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
    ("credential", re.compile(r"(password|api_key|apikey|secret|token)\s*[=:]\s*\S", re.I)),
    ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._-]{8,}")),
    ("connection-string", re.compile(r"\b\w+://[^/\s]+:[^@\s]+@")),
    ("absolute-path", re.compile(r"(/Users/|/home/[a-z]|C:\\Users)")),
    ("dev-note", re.compile(r"\b(TODO|FIXME|changelog|validated on|last updated)\b", re.I)),
    # Not a defect by itself: using the variable for a runtime path is correct,
    # documenting its name ships an expanded absolute path. Needs triage.
    ("substitution-var", re.compile(r"CLAUDE_(SKILL_DIR|PROJECT_DIR|PLUGIN_ROOT)")),
]

JUNK = ("__pycache__", ".DS_Store", ".pytest_cache", "node_modules", ".ruff_cache")

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
    total = len(text.splitlines())
    r["lines"] = total
    if total > 500:
        r["problems"].append(("spec", f"SKILL.md is {total} lines (official limit 500)"))
    elif total > 200:
        r["notes"].append(f"SKILL.md is {total} lines; preferred band is 100-200 "
                          "— move reference material to references/")

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
        r["files"].append({"path": rel, "lines": len(
            f.read_text(encoding="utf-8", errors="replace").splitlines())})

    referenced = set(re.findall(r"(?:references|scripts|assets|examples)/[\w./-]+", text))
    r["pointers"] = [{"path": p, "exists": (d / p).is_file()} for p in sorted(referenced)]
    for p in r["pointers"]:
        if not p["exists"]:
            r["problems"].append(("spec", f"SKILL.md points at {p['path']} which does not exist"))

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

    r["links"] = sorted(set(re.findall(r"https?://[^\s)>\]\"']+", text)))
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

    print(f"SKILL: {r['dir_name']}  ({r['lines']} lines, "
          f"description {r['description_chars']} chars)\n")

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
