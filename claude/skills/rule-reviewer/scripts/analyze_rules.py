#!/usr/bin/env python3
"""Mechanical half of a rules review: budget, globs, overlaps, hygiene.

Everything here is deterministic — computing it by hand invites transcription
errors and quietly differs between runs. The judgement half (derivability,
verifiability, placement) is left to the reviewer.

Usage:
    python3 analyze_rules.py [repo_root] [--json]
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# Frontmatter keys other than these are silently ignored by Claude Code.
KNOWN_KEYS = {"paths"}

HYGIENE = [
    ("credential", re.compile(r"(password|api_key|apikey|secret|token)\s*[=:]\s*\S", re.I)),
    ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._-]{8,}")),
    ("connection-string", re.compile(r"\b\w+://[^/\s]+:[^@\s]+@")),
    ("absolute-path", re.compile(r"(/Users/|/home/[a-z]|C:\\Users)")),
    ("dev-note", re.compile(r"\b(TODO|FIXME|changelog|validated on|last updated)\b", re.I)),
]


def glob_to_regex(pat):
    """Translate a glob to a regex with correct `**` vs `*` semantics.

    fnmatch is wrong here: its `*` crosses `/`, so `src/*.ts` would match
    `src/a/b.ts` and every dead-glob check would silently pass.
    """
    i, out = 0, ["^"]
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "{":
            j = pat.find("}", i)
            if j == -1:
                out.append(re.escape(c))
                i += 1
            else:
                opts = pat[i + 1:j].split(",")
                out.append("(?:" + "|".join(re.escape(o) for o in opts) + ")")
                i = j + 1
        elif c == "[":
            j = pat.find("]", i)
            if j == -1:  # not a valid bracket expression -> matches nothing
                return None
            out.append(pat[i:j + 1])
            i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    out.append("$")
    return re.compile("".join(out))


def brace_count(pat):
    """Expanded-pattern count. The whole `paths` list shares a 1,000 budget;
    an over-budget pattern is used unexpanded, so its braces match nothing."""
    n = 1
    for group in re.findall(r"\{([^}]*)\}", pat):
        n *= len(group.split(","))
    return n


def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, set()
    fm = m.group(1)
    keys = set(re.findall(r"^([A-Za-z_][\w-]*):", fm, re.M))
    paths = re.findall(r"^\s*-\s*[\"']?(.+?)[\"']?\s*$", fm, re.M)
    return paths, keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    try:
        tracked = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True, text=True, check=True,
        ).stdout.split("\n")
        tracked = [f for f in tracked if f]
    except subprocess.CalledProcessError:
        print(f"error: {root} is not a git repository", file=sys.stderr)
        return 2

    rules_dir = root / ".claude" / "rules"
    if not rules_dir.is_dir():
        print(f"error: no .claude/rules under {root}", file=sys.stderr)
        return 2

    report = {"root": str(root), "rules": [], "always_on": {}, "overlaps": {}, "hygiene": []}
    owners, unscoped_lines = {}, 0

    for f in sorted(rules_dir.rglob("*.md")):
        text = f.read_text(encoding="utf-8", errors="replace")
        n = len(text.splitlines())
        paths, keys = parse_frontmatter(text)
        rel = str(f.relative_to(rules_dir))
        entry = {"file": rel, "lines": n, "scoped": paths is not None,
                 "patterns": [], "unknown_keys": sorted(keys - KNOWN_KEYS)}

        if paths is None:
            unscoped_lines += n
        else:
            for p in paths:
                rx = glob_to_regex(p)
                hits = 0 if rx is None else sum(1 for t in tracked if rx.match(t))
                entry["patterns"].append({
                    "pattern": p, "matches": hits,
                    "expanded": brace_count(p),
                    "invalid_bracket": rx is None,
                    "dead": hits == 0,
                })
                owners.setdefault(p, []).append(rel)
            entry["expansion_total"] = sum(x["expanded"] for x in entry["patterns"])
            entry["over_budget"] = entry["expansion_total"] > 1000

        for label, rx in HYGIENE:
            for i, line in enumerate(text.splitlines(), 1):
                if rx.search(line):
                    report["hygiene"].append({"file": rel, "line": i, "kind": label,
                                              "text": line.strip()[:100]})
        report["rules"].append(entry)

    md_lines = 0
    for cand in ("CLAUDE.md", ".claude/CLAUDE.md"):
        p = root / cand
        if p.is_file():
            md_lines += len(p.read_text(encoding="utf-8", errors="replace").splitlines())

    report["always_on"] = {
        "unscoped_rule_lines": unscoped_lines,
        "claude_md_lines": md_lines,
        "total": unscoped_lines + md_lines,
        "over_target": unscoped_lines + md_lines > 200,
    }
    report["overlaps"] = {p: rs for p, rs in sorted(owners.items()) if len(rs) > 1}

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    a = report["always_on"]
    print(f"ALWAYS-ON BUDGET: {a['total']} lines "
          f"({a['unscoped_rule_lines']} unscoped rules + {a['claude_md_lines']} CLAUDE.md)"
          f"{'  ** OVER 200 TARGET **' if a['over_target'] else ''}\n")

    print(f"{'rule':<26} {'lines':>5} scope")
    print("-" * 72)
    for r in report["rules"]:
        if not r["scoped"]:
            print(f"{r['file']:<26} {r['lines']:>5} UNSCOPED — always on")
        else:
            bits = [f"{p['pattern']} ({p['matches']})"
                    + (" DEAD" if p["dead"] else "")
                    + (" BAD-BRACKET" if p["invalid_bracket"] else "")
                    for p in r["patterns"]]
            flag = "  ** EXPANSION OVER BUDGET **" if r.get("over_budget") else ""
            print(f"{r['file']:<26} {r['lines']:>5} {'; '.join(bits)}{flag}")
        if r["unknown_keys"]:
            print(f"{'':<26} {'':>5} ignored frontmatter keys: {', '.join(r['unknown_keys'])}")

    dead = [(r["file"], p["pattern"]) for r in report["rules"] for p in r["patterns"] if p["dead"]]
    if dead:
        print("\nDEAD GLOBS (rule never loads via this pattern):")
        for f, p in dead:
            print(f"  {f}: {p}")

    if report["overlaps"]:
        print("\nOVERLAPPING PATTERNS (these rules always load together):")
        for p, rs in report["overlaps"].items():
            print(f"  {p:<30} {', '.join(rs)}")

    if report["hygiene"]:
        print("\nHYGIENE:")
        for h in report["hygiene"]:
            print(f"  {h['file']}:{h['line']} [{h['kind']}] {h['text']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
