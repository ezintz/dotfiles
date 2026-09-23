# dotfiles

[dotfiles](https://dotfiles.github.io/) gives you the possibility to customize your
system. These are mine: shell (Zsh/Prezto), Git, SSH, tmux, macOS defaults, and a
global Claude Code setup.

macOS first; the installer, shell, git, tmux and Claude Code setup also work on
Linux servers (Debian/Ubuntu, Fedora, Alpine, Arch).

## Installation

On a brand-new machine, with nothing installed:

```sh
curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/install.sh | sh
```

On macOS this installs the Xcode Command Line Tools (confirm the dialog) and
Homebrew first. On a server without git, the repository is downloaded as a
tarball and turned into a git checkout once git is installed. Either way it
ends up at `~/.dotfiles` — the location is fixed, because the shell and tmux
config refer to it — and `bin/dotfiles` runs.

To install your fork, set `DOTFILES_REMOTE` (and `DOTFILES_BRANCH`):

```sh
curl -fsSL …/install.sh | DOTFILES_REMOTE=https://github.com/you/dotfiles.git sh
```

Arguments after `sh -s --` are passed on to `bin/dotfiles`, e.g.
`curl -fsSL …/install.sh | sh -s -- --yes`.

### Only the Claude Code part

The env guard, skills and agents are a Claude Code plugin, `dotfiles`, in the
`ezintz` marketplace this repository provides:

```sh
claude plugin marketplace add ezintz/dotfiles
claude plugin install dotfiles@ezintz
```

`claude/bootstrap.sh` does that and also installs what a plugin cannot carry:
the global instructions, rules and the `make` ask rules.

```sh
curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/claude/bootstrap.sh | sh
```

It replaces `~/.claude/CLAUDE.md`; the previous one is kept next to it as
`CLAUDE.md.backup-<time>`.

## Usage

After setup, `bin/` is on your `PATH` (via `zprofile`), so `dotfiles` works as a
command from anywhere. It syncs the repository, installs/updates packages, creates
the symlinks, and applies the macOS configuration.

```sh
dotfiles --no-packages \     # Do not install/update packages
  --no-sync \              # Do not sync with repository
  --no-links \             # Do not create symbolic links or set the Git identity
  --no-configuration \     # Do not apply macOS defaults
  --yes \                  # Answer every question with yes (except "restart now?")
  --dry-run                # Print what would change, change nothing
```

_Note: To be able to run the synchronization you should commit the changes that you make._

Editing files in this repository immediately affects the live configuration — the
setup symlinks them into `~` rather than copying them. Nothing is overwritten: a
file or directory already in the way is moved aside as `<name>.backup-<timestamp>`.
`~/.zshrc` is the exception — if one exists it is left alone, and `dotfiles`
prints the line to add to it.

There is no uninstall. Every link points into `~/.dotfiles`, so
`find ~ -maxdepth 3 -lname "$HOME/.dotfiles/*"` lists what to remove, and the
`.backup-*` files are what was there before.

## What's inside my dotfiles?

- **`prezto/`** — a submodule pointing at my [prezto](https://github.com/ezintz/prezto)
  fork, an awesome configuration framework for [Zsh](http://www.zsh.org/). The
  runtime configs live in `prezto/runcoms/` (`zpreztorc` for modules, `zprofile`
  for `PATH` and tool integrations).
- **`git/`** — `gitconfig`, `gitignore`, `gitattributes`, `gitk` and `tigrc`. The
  identity is read from `~/.gitauthor`, which is not tracked here and is created
  interactively on first setup.
- **`ssh/`** — a `config` that includes everything in `~/.ssh/config.d/`, so
  per-host configs can be added (and selectively committed) under `ssh/config.d/`.
- **`tmux/`** — `tmux.conf`, [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
  as a submodule, and `cmux.zsh`, which runs every cmux tab inside its own tmux
  session so shells survive cmux restarts and reboots, with Claude Code resuming
  the same conversation it was in.
- **`claude/`** — the global (`~/.claude/`) [Claude Code](https://claude.ai/code)
  setup. `claude/plugin/` is a standard Claude Code plugin: a `PreToolUse` env
  guard that makes destructive commands aimed at a non-local target ask first
  (kubectl, helm, terraform/tofu, argocd, gh, glab, git, mysql, psql, …), plus
  review, debugging and authoring skills and agents. Next to it: the global
  instructions, rules and settings, which a plugin cannot carry. The details
  live in [CLAUDE.md](CLAUDE.md).
- **`iterm2/`** — the iTerm2 preferences plist and the OneDark color scheme. Not
  symlinked: `bin/_macos` instead points iTerm2's "load preferences from a custom
  folder" at this directory, so iTerm2 reads *and writes back* the tracked plist.
  In a fork that means a dirty working tree after every iTerm2 session, and the
  plist carries a few of my absolute paths.
- **`ghostty/`** — the terminal config [cmux](https://cmux.com) renders with, since
  cmux embeds libghostty and exposes no font or cursor settings of its own.
- **`cmux/`** — cmux's own settings (shortcuts, sidebar colours, notifications),
  as opposed to how its terminal panes render.
- **`bin/_macos`** — a default set of settings for macOS (Dock, Finder, Safari and
  friends), gratuitously stolen from [@mathiasbynens](https://mths.be/dotfiles) and
  customized to my needs. **Read it before running it on your Mac.** It is
  opinionated and some of it is invasive: it turns off the "are you sure you
  want to open this application?" quarantine dialog, disables the boot chime
  (`nvram`), renames an icon inside `Dropbox.app`, resets the Launchpad
  database, and asks to quit running apps (Mail, Safari, browsers, editors) so
  their settings apply. The Safari settings only take effect if the terminal
  has Full Disk Access. `dotfiles --no-configuration` skips it entirely.
- `curlrc` and `wgetrc`.

### Private overlay

An optional `~/.dotfiles-private` directory (a separate, untracked repository) keeps
machine-specific or non-public settings out of this one. If it exists:

- `gitconfig.local`, `zpreztorc.local`, `tmux.conf.local`, `zprofile.local` and
  `zshrc.local` are symlinked into `~` alongside the tracked config;
- `Brewfile` is installed after the tracked one;
- `claude/settings.json` is merged into `~/.claude/settings.json` after the tracked
  one — this is where personal Claude Code choices such as auto permission mode
  belong, so a fork of this repository does not inherit them;
- `claude/skills/<name>/` are linked into `~/.claude/skills` one by one.

### Packages

macOS packages are declared in [`Brewfile`](Brewfile) and installed with
`brew bundle`; `brew bundle check --verbose` shows what is missing. An app that
is already in `/Applications` is adopted rather than reinstalled. Highlights:
the Kubernetes and infrastructure CLIs the Claude Code guard knows about
(kubectl, helm, k9s, argocd, opentofu, ansible), `gh`/`glab`, `jq`, `uv`,
`bats-core` for the test suite, cmux and iTerm2, Claude and Codex, and
Brave, Firefox Developer Edition, Chrome and Edge.

On Linux only the basics in [`packages/linux.txt`](packages/linux.txt) are
installed (bash, curl, git, jq, tmux, zsh), with apt, dnf, apk or pacman.

## Tests

The test suite pins the behaviour of the Claude Code env guards:

```sh
bats claude/plugin/tests/guards.bats
```

Run it after any change under `claude/plugin/hooks/`. The installer scripts are
POSIX sh; check them with `shellcheck -s sh` (see [CLAUDE.md](CLAUDE.md)).

## Credits

To all the authors of the tools that are used by dotfiles and all the other
dotfiles repositories.

## License

Non-third-party files are licensed under the WTFPL+; see [LICENSE](LICENSE).
Bundled submodules and third-party code keep their own licenses.
