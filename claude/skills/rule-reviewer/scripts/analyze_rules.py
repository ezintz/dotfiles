#!/usr/bin/env python3
"""Mechanical half of a rules review: budget, globs, overlaps, hygiene.

Everything here is deterministic — computing it by hand invites transcription
errors and quietly differs between runs. The judgement half (derivability,
verifiability, placement) is left to the reviewer.

The HYGIENE table and CHARS_PER_TOKEN below are duplicated in the other
reviewer's analyser rather than shared. That is deliberate:
bin/claude-export-skills zips one skill directory, so a module imported from
outside it does not travel and the exported skill breaks on upload. Keep the
two copies in step by hand when either changes.

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
]


# Calibrated against this repo's 70 markdown files with tiktoken cl100k_base:
# 4.25 chars/token, 5.3% mean absolute error. Enough to size a budget without
# making the analyser depend on a tokeniser it would have to install.
CHARS_PER_TOKEN = 4.25


def est_tokens(chars):
    return round(chars / CHARS_PER_TOKEN)


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
    if "paths" not in keys:
        return None, keys

    # Value of `paths:` up to the next top-level key (or end of frontmatter).
    pm = re.search(r"^paths:[ \t]*(.*?)(?=^[A-Za-z_][\w-]*:|\Z)", fm, re.M | re.S)
    body = pm.group(1) if pm else ""

    # Three spellings are all valid YAML and all appear in the wild:
    #   paths: ["src/**", "docs/*.md"]      flow sequence, possibly wrapped
    #   paths:\n  - "src/**"                block sequence
    #   paths: src/**, docs/*.md            bare comma-separated scalar
    # A spelling that is not matched silently yields zero patterns, which reads
    # downstream as "scoped, matches nothing" — no dead-glob or overlap finding
    # is produced and the scope column renders empty.
    flow = re.search(r"\[(.*)\]", body, re.S)   # greedy: bracket expressions may contain ]
    if flow:
        # The unquoted alternative has to swallow a whole bracket expression,
        # or `[src/[abc]*.ts, docs/**]` splits into "src/", "abc" and "*.ts" --
        # two globs nobody wrote, reported dead, and the real one lost.
        paths = [q or bare for q, bare in
                 re.findall(r"""["']([^"']+)["']|((?:\[[^\]]*\]|[^,\s\[\]])+)""",
                            flow.group(1))]
    elif re.search(r"^\s*-\s", body, re.M):
        paths = re.findall(r"^\s*-\s*[\"']?(.+?)[\"']?\s*$", body, re.M)
    else:
        # A `#` here is a YAML comment, not a glob character; splitting on the
        # commas first would carry it into the last pattern.
        scalar = re.sub(r"\s+#.*$", "", body.strip(), flags=re.M)
        paths = [p.strip().strip("\"'") for p in scalar.split(",") if p.strip()]
    return paths, keys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    rules_dir = root / ".claude" / "rules"
    if not rules_dir.is_dir():
        print(f"error: no .claude/rules under {root}", file=sys.stderr)
        return 2

    # $HOME holds ~/.claude/rules and is not a repository, so a hard git
    # requirement locked the analyser out of the user level entirely -- the
    # half that bills every project rather than one. Without a file list the
    # budget, frontmatter and hygiene checks all still run; only the glob match
    # counts are unavailable, so dead-glob detection is suppressed rather than
    # reported as zero matches, which would read as "every pattern is dead".
    try:
        tracked = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True, text=True, check=True,
        ).stdout.split("\n")
        tracked = [f for f in tracked if f]
        matching = True
    except (subprocess.CalledProcessError, FileNotFoundError):
        tracked, matching = [], False
        print(f"note: {root} is not a git repository — "
              f"reporting budget and hygiene, not glob matches\n", file=sys.stderr)

    report = {"root": str(root), "rules": [], "always_on": {}, "overlaps": {}, "hygiene": []}
    owners, unscoped_lines, unscoped_chars = {}, 0, 0

    for f in sorted(rules_dir.rglob("*.md")):
        text = f.read_text(encoding="utf-8", errors="replace")
        n = len(text.splitlines())
        paths, keys = parse_frontmatter(text)
        rel = str(f.relative_to(rules_dir))
        entry = {"file": rel, "lines": n, "tokens": est_tokens(len(text)),
                 "scoped": paths is not None,
                 "patterns": [], "unknown_keys": sorted(keys - KNOWN_KEYS)}

        if paths is None:
            unscoped_lines += n
            unscoped_chars += len(text)
        else:
            for p in paths:
                rx = glob_to_regex(p)
                hits = 0 if rx is None else sum(1 for t in tracked if rx.match(t))
                entry["patterns"].append({
                    "pattern": p, "matches": hits if matching else None,
                    "expanded": brace_count(p),
                    "invalid_bracket": rx is None,
                    "dead": matching and hits == 0,
                })
                owners.setdefault(p, []).append(rel)
            entry["expansion_total"] = sum(x["expanded"] for x in entry["patterns"])
            entry["over_budget"] = entry["expansion_total"] > 1000
            # `paths: []` is the one spelling the parser accepts without
            # complaint, and it is exactly the silent failure the comment above
            # warns about: scoped, so never always-on, and matching nothing, so
            # never loaded either. The rule is inert and nothing else says so.
            entry["empty_scope"] = not entry["patterns"]

        for label, rx in HYGIENE:
            for i, line in enumerate(text.splitlines(), 1):
                if rx.search(line):
                    report["hygiene"].append({"file": rel, "line": i, "kind": label,
                                              "text": line.strip()[:100]})
        report["rules"].append(entry)

    md_lines = md_chars = 0
    for cand in ("CLAUDE.md", ".claude/CLAUDE.md"):
        p = root / cand
        if p.is_file():
            t = p.read_text(encoding="utf-8", errors="replace")
            md_lines += len(t.splitlines())
            md_chars += len(t)

    report["always_on"] = {
        "unscoped_rule_lines": unscoped_lines,
        "claude_md_lines": md_lines,
        "total": unscoped_lines + md_lines,
        "tokens": est_tokens(unscoped_chars + md_chars),
        "over_target": unscoped_lines + md_lines > 200,
    }
    report["overlaps"] = {p: rs for p, rs in sorted(owners.items()) if len(rs) > 1}

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    a = report["always_on"]
    print(f"ALWAYS-ON BUDGET: {a['total']} lines / ~{a['tokens']:,} tok "
          f"({a['unscoped_rule_lines']} from unscoped rules + {a['claude_md_lines']} CLAUDE.md)"
          f"{'  ** OVER 200 TARGET **' if a['over_target'] else ''}")
    print("  charged in every session here. A scoped rule's tokens below are "
          "charged per matching edit instead.\n")

    print(f"{'rule':<26} {'lines':>5} {'~tok':>6} scope")
    print("-" * 78)
    for r in report["rules"]:
        if not r["scoped"]:
            print(f"{r['file']:<26} {r['lines']:>5} {r['tokens']:>6} UNSCOPED — always on")
        elif r.get("empty_scope"):
            print(f"{r['file']:<26} {r['lines']:>5} {r['tokens']:>6} "
                  f"EMPTY `paths:` — scoped to nothing, never loads")
        else:
            bits = [p["pattern"]
                    + (f" ({p['matches']})" if p["matches"] is not None else "")
                    + (" DEAD" if p["dead"] else "")
                    + (" BAD-BRACKET" if p["invalid_bracket"] else "")
                    for p in r["patterns"]]
            flag = "  ** EXPANSION OVER BUDGET **" if r.get("over_budget") else ""
            print(f"{r['file']:<26} {r['lines']:>5} {r['tokens']:>6} {'; '.join(bits)}{flag}")
        if r["unknown_keys"]:
            print(f"{'':<26} {'':>5} {'':>6} ignored frontmatter keys: "
                  f"{', '.join(r['unknown_keys'])}")

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
