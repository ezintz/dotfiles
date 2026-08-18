
# This shell

Bash tool calls run through zsh with a prezto config that is deployed to every
machine, and three of its settings fail in the direction that looks like success:

- **`>` will not overwrite.** `unsetopt CLOBBER` is set, so redirecting onto an
  existing file fails with "file exists" and leaves the *old* file in place —
  the regenerated output never appears and everything downstream reads stale
  data. Use `>|` to truncate on purpose.
- **`cp`, `mv` and `rm` are aliased to `-i`.** Prefix with
  `command` to bypass the alias: `command mv -f old new`.
- **Unquoted `$var` does not word-split.** Unlike bash, this zsh/prezto config
  keeps an unquoted parameter expansion as one argument even when it contains
  spaces — `for a in "x" "y z"; do cmd $a; done` passes `"y z"` as a single
  arg, not two. A loop built to fan out multi-word test cases silently
  collapses them instead of erroring, so a real pass-through bug and this
  shell quirk look identical. Use `${=var}` (`SH_WORD_SPLIT`) or an array
  (`a=(x y z); for a in $a[@]`) when splitting is actually wanted.

# .NET (Homebrew install)

Both failures below look like the tool is missing or broken rather than
mis-configured, so check these before reinstalling anything:

- **`~/.dotnet/tools` is not on PATH.** `dotnet tool install -g <tool>` reports
  success, then the tool is "command not found". Export
  `PATH="$PATH:$HOME/.dotnet/tools"` in the same call that uses it.
- **`DOTNET_ROOT` is unset**, so anything that starts the runtime *without*
  going through the `dotnet` CLI fails with "You must install .NET" even though
  `dotnet` itself works. That covers global tools and, just as often, a built
  apphost launched directly (`bin/Release/net10.0/MyApp`) — the usual way to
  benchmark or drive a GUI app under measurement. `dotnet run` masks it, so the
  failure shows up only once you switch to running the binary. Point it at the
  Homebrew install's `libexec`:
  `export DOTNET_ROOT="$(brew --prefix)/Cellar/dotnet/<version>/libexec"`
  (get `<version>` from `brew list --versions dotnet`).

# Python (Homebrew install)

- **`pip install` is refused, not broken.** The Homebrew python3 is PEP 668
  externally-managed, so installing anything — even `--user` — exits non-zero
  telling you to pass `--break-system-packages`. Don't; build a throwaway venv
  in the scratchpad instead: `python3 -m venv venv && ./venv/bin/pip install <pkg>`.

# Git

- **Use three dots, not two, against a base branch.** `git diff main...HEAD`
  diffs against the merge-base (where this branch actually forked from) —
  the same thing `gh pr diff` and `glab mr diff` compute.
- **`.claude/worktrees/` is a second checkout, not part of the tree you are
  working on.** Claude Code puts worktrees there, so a whole extra copy of the
  repo — sources, `CLAUDE.md`, `.claude/rules/` — sits under the repo root,
  gitignored. `rg` skips it (hidden directory *and* gitignored), but `find`,
  `ls`, `du` and `grep -r .claude` do not, so a raw scan double-counts every
  file and reports each rule twice as if it were duplicated. Prefer
  `git ls-files`; with `find`, add `-not -path './.claude/*'`.
