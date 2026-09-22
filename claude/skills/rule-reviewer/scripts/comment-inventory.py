#!/usr/bin/env python3
"""Dump substantive source comments so they can be diffed against the prose docs.

CLAUDE.md and .claude/rules/*.md are paid for on every edit of a file they scope
to, so a fact stored in both a rule and a code comment is billed twice forever.
This finds the second copy.

    comment-inventory.py                       # whole repo, cwd's root
    comment-inventory.py ~/src/app --rule k8s  # just that rule's paths:
    comment-inventory.py --rules               # every rule, one section each
    comment-inventory.py --rule k8s --overlap  # rank rule text against comments

--rule is the mode that matters: it reads the rule's `paths:` frontmatter and
prints the comments from exactly the files that rule is charged against, which is
the comparison a dedup pass actually needs. --overlap ranks those comments
against the rule's own bullets so a scope of 80+ files is still reviewable.
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_rules import glob_to_regex, parse_frontmatter  # noqa: E402

# Per-language comment markers. Line markers are tried longest-first so `///`
# wins over `//` and gets its own kind — an xmldoc block is API prose, which
# duplicates a rule differently than an inline aside does.
C_LIKE = ([("///", "xmldoc"), ("//", "line")], [("/*", "*/", "block")])
HASH = ([("#", "line")], [])
XML = ([], [("<!--", "-->", "xml")])
SQL = ([("--", "line")], [("/*", "*/", "block")])

SYNTAX = {}
for _ext in (".cs .ts .tsx .js .jsx .mjs .mts .cts .java .go .rs .swift .kt .kts "
             ".scala .c .h .cpp .hpp .cc .m .mm .php .dart .gradle .groovy").split():
    SYNTAX[_ext] = C_LIKE
for _ext in (".py .sh .bash .zsh .fish .rb .pl .r .yaml .yml .toml .tf .tfvars "
             ".cmake .nix .pp .ps1").split():
    SYNTAX[_ext] = HASH
for _ext in (".html .htm .xml .axaml .xaml .csproj .fsproj .vbproj .props .targets "
             ".slnx .vue .svelte .svg .plist .resx .config").split():
    SYNTAX[_ext] = XML
for _ext in ".sql .psql".split():
    SYNTAX[_ext] = SQL
SYNTAX[".css"] = ([], [("/*", "*/", "block")])
SYNTAX[".scss"] = C_LIKE
SYNTAX[".less"] = C_LIKE

# Extensionless files whose name is the whole identity.
BY_NAME = {
    "Makefile": HASH, "makefile": HASH, "GNUmakefile": HASH, "justfile": HASH,
    "Justfile": HASH, "Dockerfile": HASH, "Containerfile": HASH, "Rakefile": HASH,
    "Vagrantfile": HASH, "Brewfile": HASH, "Procfile": HASH,
}

# Vendored or generated: authored elsewhere, or authored by a tool. Either way
# its comments are not prose this repo's docs could be duplicating.
# `bin/` is deliberately absent: it is .NET build output, but it is also where
# a shell repo keeps its hand-written scripts, and that output is gitignored
# anyway so `git ls-files` never offers it. `obj/` stays — its generated .cs is
# sometimes tracked.
SKIP_DIRS = {"node_modules", "vendor", "dist", "build", "out", "target", ".venv",
             "venv", "__pycache__", "Pods", "third_party", "thirdparty",
             "Migrations", "migrations", "obj", ".next", ".nuxt",
             "coverage", "generated"}
SKIP_SUFFIXES = (".min.js", ".min.css", ".g.cs", ".designer.cs", ".generated.ts",
                 ".d.ts", ".lock", ".pb.go", "_pb2.py")

# A comment earns its place in the report by being too long to be a restatement,
# or by using the vocabulary of a constraint. Everything else is noise here.
SIGNAL = re.compile(
    r"\b(must|never|always|don'?t|do not|because|otherwise|breaks?|deliberate|"
    r"intentional|upstream|bug|workaround|cost|measured|deadlock|invariant|"
    r"requires?|assumes?|silently|trap|would|used to|regress)\b",
    re.IGNORECASE,
)
LONG_ENOUGH = 70  # chars; a one-liner shorter than this rarely carries reasoning

STOPWORDS = set("""
a an the and or but if then than that this these those is are was were be been being
to of in on at by for with from as it its into over under not no can will would should
must may might do does did done has have had one two use used using when while where
which who whom what why how all any some each both few more most other such only own
same so too very just also here there we you your our their they them he she him her
its it's don't doesn't isn't aren't via per about after before again against between
during through above below up down out off further once because otherwise always never
""".split())


def repo_root(arg: str | None) -> Path:
    if arg:
        return Path(arg).expanduser().resolve()
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print("error: not inside a git repository, and no root given",
              file=sys.stderr)
        raise SystemExit(2)
    return Path(out.stdout.strip())


SHEBANG_HASH = re.compile(r"^#!.*\b(sh|bash|zsh|ksh|fish|python[0-9.]*|perl|ruby)\b")


def syntax_for(path: Path, root: Path | None = None):
    known = SYNTAX.get(path.suffix) or BY_NAME.get(path.name)
    if known or path.suffix or root is None:
        return known
    # An extensionless `bin/` script is ordinary authored source and often the
    # most comment-dense file in a repo; only a shebang identifies it. Sniffing
    # is restricted to files with no suffix so an unknown *extension* can never
    # be dragged in this way.
    try:
        with (root / path).open(encoding="utf-8", errors="replace") as fh:
            return HASH if SHEBANG_HASH.match(fh.readline()) else None
    except OSError:
        return None


def tracked_files(root: Path) -> list[Path]:
    out = subprocess.run(["git", "-C", str(root), "ls-files"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print(f"error: {root} is not a git repository", file=sys.stderr)
        raise SystemExit(2)
    files = []
    for rel in out.stdout.split("\n"):
        if not rel:
            continue
        p = Path(rel)
        if not syntax_for(p, root):
            continue
        if SKIP_DIRS & set(p.parts[:-1]):
            continue
        if rel.endswith(SKIP_SUFFIXES):
            continue
        files.append(p)
    return files


def extract(root: Path, path: Path) -> list[tuple[int, str, str]]:
    """Return (line_number, kind, text) for each substantive comment block."""
    line_markers, block_markers = syntax_for(path, root)
    try:
        lines = (root / path).read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError:
        return []

    found: list[tuple[int, str, str]] = []
    i = 0
    while i < len(lines):
        stripped = lines[i].strip()

        # A run of same-marker line comments collapses into one block.
        marker = next((m for m, _ in line_markers if stripped.startswith(m)), None)
        if marker:
            kind = dict(line_markers)[marker]
            start = i
            body = []
            while i < len(lines):
                cur = lines[i].strip()
                # A longer marker starting here opens a different block; `#!` is
                # a shebang, not prose.
                if not cur.startswith(marker) or cur.startswith(marker + "!"):
                    break
                if any(len(m) > len(marker) and cur.startswith(m)
                       for m, _ in line_markers):
                    break
                body.append(cur[len(marker):].strip())
                i += 1
            if i == start:      # nothing consumed; don't spin
                i += 1
                continue
            text = "\n".join(body).strip()
            if keep(text, len(body)):
                found.append((start + 1, kind, text))
            continue

        opened = next(((o, c, k) for o, c, k in block_markers
                       if stripped.startswith(o)), None)
        if opened:
            open_tok, close_tok, kind = opened
            start = i
            body = []
            while i < len(lines):
                body.append(lines[i])
                if close_tok in lines[i][len(open_tok) if i == start else 0:]:
                    i += 1
                    break
                i += 1
            text = "\n".join(body).replace(open_tok, "").replace(close_tok, "")
            text = "\n".join(ln.strip().lstrip("*").strip() for ln in text.split("\n"))
            if keep(text.strip(), len(body)):
                found.append((start + 1, kind, text.strip()))
            continue

        i += 1
    return found


def keep(text: str, line_count: int) -> bool:
    if not text:
        return False
    if text.lower().startswith(("todo", "hack:", "note:")) and line_count == 1:
        return False
    if line_count >= 2:
        return True
    if len(text) >= LONG_ENOUGH:
        return True
    return bool(SIGNAL.search(text))


def rules_dir(root: Path) -> Path:
    return root / ".claude" / "rules"


def scope_of(rule: Path, files: list[Path]) -> list[Path]:
    paths, _ = parse_frontmatter(rule.read_text(encoding="utf-8"))
    if paths is None:          # unscoped: loads everywhere, so everything is in scope
        return files
    rx = [re.compile(glob_to_regex(p)) for p in paths]
    return [f for f in files if any(r.match(str(f)) for r in rx)]


def report(root: Path, files: list[Path], out) -> int:
    total = 0
    for path in sorted(files):
        comments = extract(root, path)
        if not comments:
            continue
        print(f"\n### {path}", file=out)
        for line, kind, text in comments:
            print(f"\n{path}:{line}  [{kind}]", file=out)
            for ln in text.split("\n"):
                print(f"    {ln}", file=out)
            total += 1
    return total


# --- overlap ranking -------------------------------------------------------
#
# A rule can scope 80+ files, which is more comments than anyone will read
# against every bullet. This ranks the pairs by shared rare vocabulary so the
# reading starts where a duplicate is most likely.
#
# It ranks *literal* overlap only. The duplicate it cannot see is the one that
# says the same thing in other words — a comment about "framebuffer origin"
# against a rule bullet about "flipping" scores zero — so a low score is not
# evidence of absence, and the skill says so.

SPLIT_IDENT = re.compile(r"[A-Z]?[a-z]+|[A-Z]{2,}(?![a-z])|\d+")


def terms(text: str) -> Counter:
    # Doc-comment markup (<summary>, <see cref=…>, <c>) is scaffolding every
    # xmldoc block shares, so leaving it in scores two unrelated comments as
    # similar purely for being xmldoc.
    text = re.sub(r"<[^>]*>", " ", text)
    words = Counter()
    for raw in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text):
        for part in SPLIT_IDENT.findall(raw) or [raw]:
            w = part.lower()
            if len(w) >= 3 and w not in STOPWORDS:
                words[w] += 1
    return words


def rule_units(rule: Path) -> list[tuple[int, str]]:
    """Split a rule body into bullets and paragraphs, keeping line numbers."""
    text = rule.read_text(encoding="utf-8")
    body = re.sub(r"^---\n.*?\n---\n", lambda m: "\n" * m.group(0).count("\n"),
                  text, count=1, flags=re.S)
    units: list[tuple[int, str]] = []
    cur: list[str] = []
    start = 0
    fenced = False
    for n, line in enumerate(body.split("\n"), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        s = line.strip()
        starts_unit = s.startswith(("-", "*", "|")) or s.startswith("#")
        if not s or starts_unit:
            if cur:
                units.append((start, " ".join(cur)))
                cur = []
        if s.startswith("#") or not s:
            continue
        if not cur:
            start = n
        cur.append(s.lstrip("-* "))
    if cur:
        units.append((start, " ".join(cur)))
    return [(n, t) for n, t in units if len(t) >= 40]


def cosine(a: Counter, b: Counter, idf: dict[str, float]) -> float:
    shared = set(a) & set(b)
    if not shared:
        return 0.0
    num = sum(a[t] * b[t] * idf.get(t, 0.0) ** 2 for t in shared)
    na = math.sqrt(sum(v * v * idf.get(t, 0.0) ** 2 for t, v in a.items()))
    nb = math.sqrt(sum(v * v * idf.get(t, 0.0) ** 2 for t, v in b.items()))
    return num / (na * nb) if na and nb else 0.0


def overlap(root: Path, rule: Path, scoped: list[Path], out,
            threshold: float, top: int) -> None:
    comments = [(p, ln, kind, txt) for p in sorted(scoped)
                for ln, kind, txt in extract(root, p)]
    units = rule_units(rule)
    if not comments or not units:
        print(f"\n-- no overlap candidates ({len(units)} rule units, "
              f"{len(comments)} comments)", file=out)
        return

    docs = [terms(c[3]) for c in comments]
    df: Counter = Counter()
    for d in docs:
        df.update(set(d))
    n = len(docs)
    idf = {t: math.log(1 + n / c) for t, c in df.items()}

    pairs = []
    for line, text in units:
        ut = terms(text)
        for (path, cline, kind, ctext), d in zip(comments, docs):
            s = cosine(ut, d, idf)
            if s >= threshold:
                pairs.append((s, line, text, path, cline, kind, ctext))
    pairs.sort(reverse=True, key=lambda p: p[0])

    print(f"\n{'=' * 70}\n== OVERLAP: {rule.name} — {len(pairs)} pair(s) at or above "
          f"{threshold:.2f}\n{'=' * 70}", file=out)
    print("Shared-vocabulary ranking, not a verdict: a high score can be two "
          "statements\nthat merely share jargon, and a duplicate worded "
          "differently scores zero.", file=out)
    for s, line, text, path, cline, kind, ctext in pairs[:top]:
        print(f"\n--- {s:.2f}  {rule.name}:{line}  <->  {path}:{cline} [{kind}]",
              file=out)
        print(f"  RULE    {text[:400]}", file=out)
        for ln in ctext.split("\n")[:8]:
            print(f"  COMMENT {ln}", file=out)
    if len(pairs) > top:
        print(f"\n-- {len(pairs) - top} further pair(s) below the top {top}",
              file=out)


def resolve_rule(root: Path, name: str) -> Path:
    # Bare name first: `--rule packaging` must not resolve to a packaging/
    # directory that happens to sit in the repo root.
    rule = rules_dir(root) / (name if name.endswith(".md") else f"{name}.md")
    if rule.is_file():
        return rule
    p = Path(name).expanduser()
    if p.is_file():
        return p
    print(f"no such rule: {name}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", nargs="?", help="repo root (default: git toplevel of cwd)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--rule", help="only files matched by this rule's paths: (name or path)")
    g.add_argument("--rules", action="store_true", help="one section per rule file")
    ap.add_argument("--overlap", action="store_true",
                    help="rank rule text against the scoped comments by shared rare terms")
    ap.add_argument("--threshold", type=float, default=0.20,
                    help="minimum overlap score to report (default: 0.20)")
    ap.add_argument("--top", type=int, default=12, help="pairs to print per rule")
    ap.add_argument("--out", help="write to this file instead of stdout")
    args = ap.parse_args()

    root = repo_root(args.root)
    files = tracked_files(root)
    out = open(args.out, "w", encoding="utf-8") if args.out else sys.stdout

    try:
        if args.rules or args.rule:
            rdir = rules_dir(root)
            if args.rules:
                rules = sorted(rdir.glob("*.md")) if rdir.is_dir() else []
                if not rules:
                    print(f"no rules found under {rdir}", file=sys.stderr)
                    return 1
            else:
                rules = [resolve_rule(root, args.rule)]

            for rule in rules:
                scoped = scope_of(rule, files)
                print(f"\n\n{'=' * 70}\n== {rule.name}  ({len(scoped)} files in scope)"
                      f"\n{'=' * 70}", file=out)
                if args.overlap:
                    overlap(root, rule, scoped, out, args.threshold, args.top)
                else:
                    n = report(root, scoped, out)
                    print(f"\n-- {n} substantive comments under {rule.name}", file=out)
        else:
            if args.overlap:
                print("--overlap needs --rule or --rules", file=sys.stderr)
                return 2
            n = report(root, files, out)
            print(f"\n-- {n} substantive comments across {len(files)} files", file=out)
    finally:
        if args.out:
            out.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
