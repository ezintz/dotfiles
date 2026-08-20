# dotfiles

[dotfiles](https://dotfiles.github.io/) gives you the possibility to customize your
system. These are mine: shell (Zsh/Prezto), Git, SSH, tmux, macOS defaults, and a
global Claude Code setup.

macOS only.

## Prerequisites

- macOS with the Xcode command line tools (`xcode-select --install`)
- [Zsh](http://www.zsh.org/) 4.3.17 or higher, for the automated installation and
  [prezto](https://github.com/ezintz/prezto)

Homebrew is installed by `bin/dotfiles` if it is missing.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/bin/dotfiles | /usr/bin/env zsh
```

This clones the repository to `~/.dotfiles` and runs the full setup. If you cloned
it yourself, run `git submodule update --init --recursive` first.

## Usage

After setup, `bin/` is on your `PATH` (via `zprofile`), so `dotfiles` works as a
command from anywhere. It syncs the repository, installs/updates packages, creates
the symlinks, and applies the macOS configuration.

```sh
dotfiles --no-configuration \ # Do not apply any configuration
  --no-packages \ # Do not install/update packages
  --no-sync \ # Do not sync with repository
  --no-links # Do not create symbolic links
```

_Note: To be able to run the synchronization you should commit the changes that you make._

Editing files in this repository immediately affects the live configuration — the
setup symlinks them into `~` rather than copying them.

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
- **`tmux/`** — `tmux.conf` plus [tpm](https://github.com/tmux-plugins/tpm),
  tmux-sensible and tmux-yank as submodules.
- **`claude/`** — the global (`~/.claude/`) [Claude Code](https://claude.ai/code)
  setup: instructions, skills, agents, rules, settings, and a `PreToolUse` env
  guard that makes destructive commands aimed at a non-local target ask first.
  The details live in [CLAUDE.md](CLAUDE.md).
- **`iterm2/`** — the iTerm2 preferences plist and the OneDark color scheme. These
  are not applied by `bin/dotfiles`; import them manually in iTerm2's preferences.
- **`bin/_macos`** — a default set of settings for macOS (Dock, Finder, Safari and
  friends), gratuitously stolen from [@mathiasbynens](https://mths.be/dotfiles) and
  customized to my needs.
- `curlrc` and `wgetrc`.

### Private overlay

An optional `~/.dotfiles-private` directory (a separate, untracked repository) can
hold `gitconfig.local`, `zpreztorc.local`, `tmux.conf.local` and `zprofile.local`.
If it exists, those files are symlinked into `~` alongside the tracked config, so
machine-specific or non-public settings never have to land in this repository.

### Packages

Homebrew formulae and casks are defined inline at the top of `bin/dotfiles` — edit
that file to add or remove packages. It currently installs, among others:

- [ack](http://beyondgrep.com/): Tool like grep, optimized for programmers.
- [bat](https://github.com/sharkdp/bat): A `cat` clone with syntax highlighting.
- [bats-core](https://github.com/bats-core/bats-core): Test framework for Bash; runs this repository's test suite.
- [coreutils](http://www.gnu.org/software/coreutils/): The GNU Core Utilities.
- [curl](http://curl.haxx.se/): Tool for client-side URL transfers.
- [duti](https://github.com/moretension/duti): Sets default applications for document types.
- [fortune](<https://en.wikipedia.org/wiki/Fortune_(Unix)>): Displays a pseudorandom message from a database of quotations.
- [git](http://git-scm.com/), [git-extras](https://github.com/tj/git-extras): Distributed version control system, and some extras for it.
- [helm](https://helm.sh/), [kubernetes-cli](https://kubernetes.io/docs/reference/kubectl/): Kubernetes package manager and CLI.
- [jq](https://jqlang.github.io/jq/): Command-line JSON processor.
- [node](http://nodejs.org/): JavaScript runtime.
- [opentofu](https://opentofu.org/): Open source infrastructure as code.
- [tmux](https://tmux.github.io/): Terminal multiplexer.
- [wget](http://www.gnu.org/software/wget/): GNU Wget is a free software package for retrieving files.
- [wireguard-tools](https://www.wireguard.com/): WireGuard VPN tooling.

Casks cover the GUI side: 1Password, Google Chrome, Microsoft Edge, OrbStack,
Sequel Ace, Slack, Stats, Visual Studio Code, JetBrains Toolbox, and the
JetBrains Mono Nerd Font.

## Tests

There is no linting. The one test suite pins the behaviour of the Claude Code env
guards:

```sh
bats claude/tests/guards.bats
```

Run it after any change under `claude/hooks/`.

## Credits

To all the authors of the tools that are used by dotfiles and all the other
dotfiles repositories.

## License

Non-third-party files are licensed under the WTFPL+; see [LICENSE](LICENSE).
Bundled submodules and third-party code keep their own licenses.
