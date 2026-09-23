# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What This Repo Is

A macOS dotfiles repository managing shell config (Zsh/Prezto), Git, SSH, Tmux,
macOS defaults, and the global Claude Code setup. The mechanism is symlinking
files from this repo into `~`, so **editing a file here changes the live
configuration immediately**.

## Installation & Usage

```bash
bin/dotfiles                     # install, or re-run after changes
bin/dotfiles --no-packages       # skip Homebrew/npm installs
bin/dotfiles --no-sync           # skip git pull
bin/dotfiles --no-links          # skip symlink creation
bin/dotfiles --no-configuration  # skip macOS defaults
```

`bin/` is on PATH via `zprofile`, so `dotfiles` works from anywhere.
After cloning: `git submodule update --init --recursive`.

## Testing

There is no linting. The one suite covers the Claude Code env guards:

```bash
bats claude/tests/guards.bats    # bats-core is in DESIRED_HOMEBREW_FORMULAE
```

**Run it after any change under `claude/hooks/`.**

Most cases are behavioural — this command passes, that one asks. The vocab-drift
cases are different: they scrape `kubectl`/`helm`/`tofu --help` and fail if a
real subcommand is missing from that guard's `GUARD_VOCAB`. A verb the guard has
never heard of matches nothing and is silently treated as read-only, which is the
one failure a hand-written case cannot reach — you cannot test for a verb you do
not know exists. Keep them working rather than deleting them when they go red.

## Architecture

### Symlinks

`bin/dotfiles` symlinks config into `~` (`git/gitconfig` → `~/.gitconfig`,
`ssh/config` → `~/.ssh/config`, `tmux/tmux.conf` → `~/.tmux.conf`, …).

- `.zshrc` is linked **only if `~/.zshrc` does not already exist**, so
  machine-local shell config can live there untracked.
- `~/.dotfiles-private` is an optional untracked overlay repo holding
  `gitconfig.local`, `zpreztorc.local`, `tmux.conf.local`, `zprofile.local`;
  `mirror_local_files` links them alongside the tracked config.
- `~/.gitauthor` (untracked) supplies the git identity, created interactively on
  first setup.

### Shell (Prezto)

`prezto/` is a submodule of a custom fork (`github.com/ezintz/prezto`); runtime
configs live in `prezto/runcoms/` — `zpreztorc` (modules, the usual file to
edit), `zprofile` (PATH, env, tool integrations), `zshrc` (sources Prezto).
`~/.zprofile.local` is sourced at the end of `zprofile` for machine-specific env.

### Other

- `ssh/config` includes `~/.ssh/config.d/*`; per-host configs go in
  `ssh/config.d/`, which is gitignored selectively.
- `bin/_macos` sets macOS defaults; sourced by `bin/dotfiles`.
- Homebrew formulae, casks and npm packages are defined **inline in
  `bin/dotfiles`**, not a Brewfile.
- `iterm2/` tracks the prefs plist and colour scheme — import manually, nothing
  applies them.
- Submodules: `prezto`, `tmux/plugins/{tpm,tmux-sensible,tmux-yank}`.

## Claude Code Configuration (`claude/`)

Manages the **global** `~/.claude/` setup, not project-local config.

| Path | Linked as | Note |
|---|---|---|
| `global-instructions.md` | `~/.claude/CLAUDE.md` | renamed in-repo on purpose |
| `hooks/` | `~/.claude/hooks/` | the env guard |
| `skills/`, `agents/`, `rules/`, `refs/` | per-entry | **not** whole directories |
| `settings.json` | deep-merged into `~/.claude/settings.json` | **not** symlinked |
| `mcp.json` | deep-merged into `~/.claude.json` | user-scope MCP servers |
| `statusline-command.sh` | `~/.claude/statusline-command.sh` | |

- **`global-instructions.md` is renamed** so Claude Code's auto-discovery does
  not load it a second time as a project file while working in this repo. It
  costs context in *every session of every repo*, so it holds only what changes
  behaviour anywhere — command discipline, tool usage. Build/test/extend
  knowledge belongs in this file instead. When in doubt: would this help in an
  unrelated repo six months from now? If not, it goes here.
- **Per-entry linking** for `skills/`, `agents/`, `rules/`, `refs/`, because
  `~/.claude/skills` and `~/.claude/rules` also contain plugin-managed entries
  (e.g. context7) that must not be clobbered. `refs/` holds docs too long to
  inline; they are not auto-discovered, so a skill or rule must link them by
  relative path (`../../refs/<name>.md` from `claude/skills/<name>/SKILL.md`).
- **`settings.json` is deep-merged** via `jq` (`merge_json` in `bin/dotfiles`).
  Tracked keys win; machine-local keys already present (`model`, `effortLevel`)
  survive. Rule syntax is `Bash(cmd *)` — the trailing **space-star** enforces a
  word boundary, so `Bash(ansible *)` does not match `ansible-lint`, while
  `Bash(make deploy*)` deliberately also matches `make deploy-prod`. Rules are
  matched per subcommand of a compound command, and `ask` rules still prompt even
  when a hook returns `allow`, so the two layers compose.
- **MCP secrets are never tracked.** `claude/mcp.json` references them as
  `${VAR}` and they are exported from `~/.zprofile.local`.
- **`bootstrap.sh` cannot read the repo** (it is fetched over HTTP for machines
  without a clone), so its `PROFILES` list must be updated by hand when a guard
  profile is added, and its `ask_rules` list when a wrapper is added to
  `settings.json`. Its merges are additive — anything the user added by hand
  survives.
- `bin/claude-export-skills` zips `~/.claude/skills/*` for claude.ai. Not run by
  `bin/dotfiles`.

### The env guard (`claude/hooks/`)

A PreToolUse hook: a destructive command aimed at a non-local target returns
`permissionDecision: "ask"` instead of running under the ambient permission mode.

- `env-guard.sh` — the **only** registered hook. Reads the tool JSON once,
  expands the command (script bodies, make recipes, heredocs, pipes), and
  dispatches to every `guards/*.guard` profile.
- `guard-lib.sh` — command-line parsing: segmentation, wrapper/`eval` detection,
  exact-token subcommand matching, flag-value skipping. This is what keeps
  `helm template test chart` from reading as `helm test`.
- `guards/<tool>.guard` — one profile per tool: verb vocabulary as data plus
  `guard_resolve_target()` and optional `guard_classify_extra()` / `guard_reason()`.
  Pick a classification style with `GUARD_STYLE`: `vocab` (fixed subcommand list),
  `positional` (object-verb grammar), or `sql` (the verb is a SQL keyword that
  never appears in argv, so `guard_classify_extra` *is* the classifier).
  Files prefixed `_` are shared helpers; the dispatcher only globs `*.guard`.

Both sources are heavily commented at the point of use — **read the function
before changing it**; the rationale for every non-obvious branch is there.

**Per-project allowlist** — `~/.claude/guard-allow.conf`, one rule per line:

```
<project dir> | <binary> | <target glob> | <action glob>
~/work/acme-api | mysql | host bench-db.internal* | *
```

Matched against the *resolved* target, i.e. the exact text the prompt would have
shown, so what is allowed is what would have been read and approved anyway. The
file must live in `$HOME` and be owned by the user running the hook: an allowlist
a session could write into the repo it is working in would be self-approval with
extra steps.

#### Writing or tuning a guard

Every rule below exists because breaking it produced a real bug here.

1. **Gate what cannot be walked back; let collaboration through.** The test is
   reversibility, not visibility. Opening/commenting on PRs, reviewing, editing a
   description and ordinary pushes — including force-pushing your own topic
   branch — must never prompt. `pr merge`, `repo delete`, `release create`,
   `secret set`, `workflow run`, `api -X DELETE`, and force-push/branch-delete/
   `--mirror` against a protected branch must. A guard that prompts on routine
   work gets approved reflexively, which destroys its value where it matters.
2. **Encode the distinction as `group verb` pairs, not a blanket verb list** —
   `create` means something very different on `pr` than on `repo`. See
   `GH_SAFE_PAIRS` / `GLAB_SAFE_PAIRS`.
3. **Resolve the target from what the command itself names**, in preference to
   ambient state (the cwd's remote, the current kube context). A prompt naming
   the *wrong* target is worse than no prompt — it is how the wrong environment
   gets approved. This bug class has appeared four times.
4. **Enumerate the exact values of a safety flag; never prefix-match.**
   `--dry-run|--dry-run=.*` matched `--dry-run=false` and waved real mutations
   through.
5. **Writing ≠ executing, and the consumer decides which it is.** Text that
   names a command — a runbook, a commit message, a JSON blob, a `-e` SQL
   string — must never prompt; the same text handed to something that runs it
   must. A shell or `ssh` executes a heredoc body, an interpreter executes it as
   opaque code, `cat`/`tee`/`git commit -F -` do not. Likewise quotes are
   stripped only where they delimit a payload the guard extracted, never
   blanket-fashion off a whole command line.
6. **Guard only where the decision needs runtime state** (which kube context, TF
   workspace, Argo CD server, repo). For a purely syntactic rule a
   `permissions.ask` entry in `settings.json` is cheaper than a hook. A wrapper
   is not automatically syntactic: `helmfile`, `terragrunt`, `skaffold`,
   `ansible` all have a resolvable target and a real verb grammar, so they earn
   profiles and let their read-only halves through. `make` is the exception — a
   target name says nothing about what it runs — so it stays a name-based `ask`
   rule backing up the recipe expansion in `guard_make_recipes`.
7. **Add test cases in both directions** — the read-only command that must pass
   *and* the mutation that must still ask. Fictional cluster/release/host names
   only, never real ones. For a test pinning a *fix*, **break the fix and watch
   the test fail** before trusting it: two tests here passed against reverted
   code, one because the `cp -i` alias silently blocked the revert, the other
   because it reproduced the symptom rather than the harm. A green suite proves
   nothing about a bug it never actually reproduced.
8. **Benchmark under `/bin/bash`, not the Homebrew bash on `$PATH`.** The hook
   runs under its shebang, i.e. bash 3.2, where `${var//[chars]/}` is quadratic —
   stripping `;(),` from a single 9 KB word takes **44 seconds** there against
   31 ms under bash 5, and a `-e "delete … where id in (1,…,2000)"` is exactly
   one such word. That is not a slow hook, it is a Bash call that never returns.
   In anything running per segment or per token, avoid forks: no `printf | tr`,
   and return values through a global rather than `$(…)`. Where a scan cannot
   leave the shell, bound the input. `bats -f "does not hang"` pins this; a
   correctness test does not, because a statement whose verb comes first returns
   before reaching the expensive token.
9. **Adding a tool is one new `.guard` file**, plus its filename in
   `bootstrap.sh`'s `PROFILES` list. `bin/dotfiles` links `guards/` as a whole
   directory and the hook is already registered.
