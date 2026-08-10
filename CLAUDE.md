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

There are no tests or linting commands — this is a configuration repo.

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
- `bootstrap.sh` — standalone installer for machines without this repo cloned (`curl -fsSL .../claude/bootstrap.sh | sh`); installs global instructions plus the kubectl/terraform env-guard hooks and registers them in `~/.claude/settings.json`. Safe to re-run.
- `global-instructions.md` → symlinked to `~/.claude/CLAUDE.md`. It is named differently in-repo on purpose, so Claude Code's auto-discovery doesn't also load it a second time as a project file when working inside this dotfiles repo.
- `hooks/` — PreToolUse guard scripts (kubectl/helm, terraform/tofu) that block destructive commands against the wrong environment.
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
