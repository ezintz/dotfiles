# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A macOS dotfiles repository that manages shell configuration (Zsh/Prezto), Git, SSH, Tmux, and system defaults. The main mechanism is symlinking files from this repo into `~`.

## Installation & Usage

```bash
# Initial install or re-run after changes
bin/dotfiles

# Skip specific phases
bin/dotfiles --no-packages   # skip Homebrew/npm installs
bin/dotfiles --no-sync       # skip git pull
bin/dotfiles --no-links      # skip symlink creation
bin/dotfiles --no-configuration  # skip macOS defaults
```

After setup, `bin/` is in PATH (via `zprofile`), so `dotfiles` works as a command from anywhere.

There is no linting. The one test suite is `claude/tests/guards.bats`, which pins
the behaviour of the Claude Code env guards:

```bash
bats claude/tests/guards.bats   # bats-core is in DESIRED_HOMEBREW_FORMULAE
```

Run it after any change under `claude/hooks/`.

## Architecture

### Symlink Strategy

`bin/dotfiles` symlinks files directly into `~`. For example:
- `git/gitconfig` → `~/.gitconfig` (also gitignore, gitattributes, gitk, tigrc)
- `ssh/config` → `~/.ssh/config`
- `tmux/tmux.conf` → `~/.tmux.conf`

`.zshrc` is a special case: it is only symlinked if `~/.zshrc` does not already exist, allowing machine-local shell config to live there without being overwritten.

Editing files in this repo immediately affects the live configuration.

An optional private overlay directory, `~/.dotfiles-private` (a separate, non-tracked repo), can hold `gitconfig.local`, `zpreztorc.local`, `tmux.conf.local`, and `zprofile.local`. If present, `bin/dotfiles` symlinks them into `~` alongside the tracked config (`mirror_local_files` in `bin/dotfiles`).

### Shell Configuration (Prezto)

`prezto/` is a git submodule pointing to a custom fork (`github.com/ezintz/prezto`). Runtime configs live in `prezto/runcoms/`:
- `zpreztorc` — which Prezto modules are loaded (the main file to edit for shell behavior)
- `zprofile` — PATH, environment variables, tool integrations (OrbStack, krew, kubeconfig)
- `zshrc` — minimal, just sources Prezto init

`~/.zprofile.local` is sourced at the end of `zprofile` if it exists — use it for machine-specific env vars that should not be tracked in this repo.

### Modular SSH Config

`ssh/config` includes all files from `~/.ssh/config.d/*`. Per-host or per-domain configs belong in `ssh/config.d/`. The `.gitignore` there allows selectively committing host configs.

### macOS System Defaults

`bin/_macos` is a standalone script (~850 lines) that sets macOS defaults for Dock, Finder, Safari, etc. It's sourced by `bin/dotfiles` during the configuration phase.

### Git Submodules

- `prezto` — Zsh framework (custom fork)
- `tmux/plugins/tpm` — Tmux Plugin Manager
- `tmux/plugins/tmux-sensible`
- `tmux/plugins/tmux-yank`

After cloning, run `git submodule update --init --recursive`.

### Claude Code Configuration (`claude/`)

`claude/` manages the *global* (`~/.claude/`) Claude Code setup, not project-local config:
- `bootstrap.sh` — standalone installer for machines without this repo cloned (`curl -fsSL .../claude/bootstrap.sh | sh`); installs global instructions plus the env-guard hook and registers it in `~/.claude/settings.json`. Safe to re-run. It fetches over HTTP and so cannot glob a remote directory: its `PROFILES` list must be updated by hand when a guard profile is added.
- `global-instructions.md` → symlinked to `~/.claude/CLAUDE.md`. It is named differently in-repo on purpose, so Claude Code's auto-discovery doesn't also load it a second time as a project file when working inside this dotfiles repo. **It costs context in every session of every repo**, so it holds only things that change how Claude behaves *anywhere* — command discipline, tool usage. How something here is built, tested or extended is maintenance knowledge and belongs in this file instead; it is loaded automatically whenever the work is actually happening in this repo. When in doubt: would this help in an unrelated repo six months from now? If not, it goes here.
- `hooks/` — the PreToolUse env guard: destructive commands aimed at a non-local target get `permissionDecision: "ask"` instead of running under the ambient permission mode.
  - `env-guard.sh` is the **only** registered hook. It reads the tool JSON once and dispatches to every profile in `hooks/guards/*.guard`. One process per Bash call instead of one per guarded tool (~13ms vs ~141ms when nothing matches).
  - `guard-lib.sh` holds the command-line parsing — segmentation, wrapper/`eval` detection, exact-token subcommand matching, flag-value skipping. This is the part that keeps `helm template test chart` from reading as `helm test`.
  - **Writing ≠ executing.** Heredoc bodies are stripped before classification (`guard_strip_heredocs`), so `cat > runbook.md <<EOF … kubectl --context production delete … EOF` documents a command without prompting. The line that *opens* the heredoc is kept, because `kubectl apply -f - <<EOF` really does apply. Conversely `guard_script_bodies` reads the contents of scripts the command executes (`bash deploy.sh`, `./deploy.sh`, `source x.sh`) — one level deep, bounded to 4 files × 64 KiB — so a destructive command is caught when it runs from a file, not when it is written to one.
  - Keep `guard_tokenize` fork-free. It runs for every segment of every command times every profile; forking `printf | tr` per token there cost ~8ms per call on its own.
  - `guards/<tool>.guard` is a **profile**: the verb vocabulary as data, plus `guard_resolve_target()` (and optionally `guard_classify_extra()` / `guard_reason()`) as code. Currently kubectl, helm, terraform+tofu, openstack, argocd, git, gh, glab. Files prefixed `_` are shared helpers, not profiles — the dispatcher only globs `*.guard`.
  - Two classification styles: `vocab` (fixed subcommand list, e.g. kubectl/terraform) and `positional` (open-ended object-verb grammar, e.g. openstack/argocd/gh). Pick with `GUARD_STYLE`.

#### Writing or tuning a guard

Read this before adding a profile or widening what one lets through. Every rule
below exists because breaking it produced a real bug in this repo.

1. **Gate what cannot be walked back; let collaboration through.** The test is
   reversibility, not visibility. Opening and commenting on PRs/MRs, reviewing,
   editing a description, and ordinary pushes — including force-pushing your own
   topic branch — must never prompt. `pr merge`, `repo delete`, `release create`,
   `secret set`, `workflow run`, `api -X DELETE`, and force-push / branch-delete /
   `--mirror` against a protected branch must. A guard that prompts on routine work
   gets approved reflexively, which destroys its value for the cases that matter.
2. **Encode the distinction as `group verb` pairs, not a blanket verb list.**
   `create` means something very different on `pr` than on `repo`. See
   `GH_SAFE_PAIRS` / `GLAB_SAFE_PAIRS`.
3. **Resolve the target from what the command itself names**, in preference to
   ambient state (the cwd's git remote, the current kube context). A prompt that
   names the *wrong* target is worse than no prompt — it is how the wrong
   environment gets approved. This bug class appeared three separate times:
   `gh repo delete acme/scratch` reporting the current checkout, `git push --mirror
   backup` reporting origin, `git -C dir push` reading the `-C` value as the remote.
4. **Enumerate the exact values of a safety flag; never prefix-match.**
   `--dry-run|--dry-run=.*` matched `--dry-run=false` and waved real helm and
   argocd mutations straight through.
5. **Guard only where the decision needs runtime state** (which kube context, which
   TF workspace, which Argo CD server, which repo). For a purely syntactic rule a
   `permissions.ask` entry in `settings.json` is cheaper than a hook.
6. **Add test cases in both directions** to `claude/tests/guards.bats` — the
   read-only command that must pass *and* the mutation that must still ask — and
   run `bats claude/tests/guards.bats`. Use fictional cluster/release/host names,
   never real ones.
7. **Adding a tool is one new `.guard` file**, plus its filename in `bootstrap.sh`'s
   `PROFILES` list. `bin/dotfiles` links `guards/` as a whole directory and the hook
   is already registered, so nothing else changes.
- `skills/`, `agents/`, `rules/`, and `refs/` → linked **per-entry** (not as whole directories), since `~/.claude/skills` and `~/.claude/rules` can already contain plugin-managed entries (e.g. context7) that must not be clobbered. `refs/` holds reference docs too long to inline into a skill or rule — they aren't auto-discovered by Claude Code, so a skill or rule must link to them explicitly by path (from a skill at `claude/skills/<name>/SKILL.md`, that's a `../../refs/<ref-name>.md` relative link). `agents/` holds subagent definitions (flat `.md` files, like `rules/`) that skills can dispatch to via the Agent tool for a second opinion or a parallel multi-perspective pass.
- `settings.json` → **deep-merged** into `~/.claude/settings.json` via `jq` (`merge_json` in `bin/dotfiles`), not symlinked like everything else in this repo. Tracked keys win, but machine-local keys (e.g. `model`, `permissions`) already in the destination are preserved.
- `statusline-command.sh` → symlinked to `~/.claude/statusline-command.sh`.

`bin/claude-export-skills` is a separate utility (not run by `bin/dotfiles`) that zips up `~/.claude/skills/*` for uploading to claude.ai.

### Package Definitions

Homebrew formulae, casks, and npm packages are defined inline in `bin/dotfiles` (not a Brewfile). Edit that file to add/remove packages.

### iTerm2

`iterm2/` tracks the iTerm2 preferences plist and the OneDark color scheme. These are not auto-applied by `bin/dotfiles` — import them manually in iTerm2 preferences.

### Git Identity

`bin/dotfiles` reads `~/.gitauthor` (not tracked in this repo) for user name and email. This file is created interactively during first setup.
