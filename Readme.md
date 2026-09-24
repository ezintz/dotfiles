# dotfiles

[dotfiles](https://dotfiles.github.io/) gives you the possibility to customize your
system. These are mine: shell (Zsh/Prezto), Git, SSH, tmux, macOS defaults and
apps, and a global Claude Code setup.

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

### A new Mac, step by step

1. **Sign in to the App Store.** Xcode, Keynote, Numbers and Pages are installed
   through it (`mas`); without a sign-in `brew bundle` reports those four as
   failed and installs everything else.
2. **Run `install.sh`** as above and answer its questions (`--yes` answers
   the routine ones). Once the packages are in, it offers to back up the
   [private overlay](#private-overlay): pick the forge, log in, and pick
   another machine's overlay to start from — your settings, packages, SSH host
   files and Git identity then arrive in the same run. It asks for your Git
   identity if the overlay has none.
3. **Afterwards, by hand** — none of this belongs in a repository:
   - SSH keys into `~/.ssh` (host files come with the overlay, see
     [SSH](#ssh));
   - log in to the CLIs you use: `gh auth login`, `glab auth login`, cloud and
     Kubernetes credentials (`~/.kube/config`);
   - VS Code: Accounts → Backup and Sync Settings… (see [VS Code](#vs-code));
   - the keys in `~/.config/dotfiles/secrets.env`, which is never backed up —
     for me `GITHUB_PAT`, `CONTEXT7_API_KEY` and `CGC_API_KEY` (see
     [Secrets](#secrets));
   - grant the terminal Full Disk Access and re-run `dotfiles` if you want the
     Safari settings in `bin/_macos` to apply;
   - log out and back in: some macOS defaults only apply then.

### Only the Claude Code part

The env guard, skills and agents are a Claude Code plugin, `dotfiles`, in the
`ezintz` marketplace this repository provides:

```sh
claude plugin marketplace add ezintz/dotfiles
claude plugin install dotfiles@ezintz
```

That is the guard, skills and agents only. The global instructions, rules,
settings and the other plugins listed in `claude/settings.json` come with the
full install above; a plugin cannot carry them.

## Usage

After setup, `bin/` is on your `PATH` (via `zprofile`), so `dotfiles` works as a
command from anywhere. In order, it: pulls this repository and the private
overlay (and restarts itself if the pull changed it), installs packages, offers
to back up the private overlay once, links the config into `~` and sets up
Claude Code, asks for the Git identity if missing, applies the macOS defaults,
and finally offers to commit and push whatever changed in the overlay. Every
step can be skipped, and re-runs are safe:

```sh
dotfiles --no-packages \     # Do not install/update packages
  --no-sync \              # Do not sync with repository
  --no-links \             # Do not create symbolic links or set the Git identity
  --no-configuration \     # Do not apply macOS defaults
  --no-overlay \           # Do not set up or back up the private overlay repository
  --yes \                  # Answer every question with yes (except "restart now?"
                           # and anything that pushes)
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
  for `PATH` and tool integrations). Changes there are committed and pushed in
  the submodule, then the new submodule commit is committed here.
- **`git/`** — `gitconfig`, `gitignore` and `gitattributes`, linked into `~`.
  The identity comes from `gitauthor` in the private overlay, created
  interactively on first setup; `gitconfig` fails a commit rather than invent
  one when it is missing. `gitk` and `tigrc` are kept here but not linked.
- **`ssh/`** — see [SSH](#ssh).
- **`tmux/`** — `tmux.conf`, [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
  as a submodule, and `cmux.zsh`, which runs every cmux tab inside its own tmux
  session so shells survive cmux restarts and reboots, with Claude Code resuming
  the same conversation it was in.
- **`claude/`** — see [Claude Code](#claude-code).
- **`iterm2/`** — the iTerm2 preferences plist and the OneDark color scheme. Not
  symlinked: `bin/_macos` instead points iTerm2's "load preferences from a custom
  folder" at this directory, so iTerm2 reads *and writes back* the tracked plist.
  In a fork that means a dirty working tree after every iTerm2 session, and the
  plist carries a few of my absolute paths.
- **`ghostty/`** — the terminal config [cmux](https://cmux.com) renders with, since
  cmux embeds libghostty and exposes no font or cursor settings of its own.
- **`cmux/`** — cmux's own settings (shortcuts, sidebar colours, notifications),
  as opposed to how its terminal panes render.
- **`bin/_macos`** — a default set of settings for macOS (Dock, Finder, Safari,
  AltTab and friends), gratuitously stolen from [@mathiasbynens](https://mths.be/dotfiles)
  and customized to my needs. **Read it before running it on your Mac.** It is
  opinionated and some of it is invasive: it turns off the "are you sure you
  want to open this application?" quarantine dialog, disables the boot chime
  (`nvram`), renames an icon inside `Dropbox.app`, resets the Launchpad
  database, and asks to quit running apps (Mail, Safari, browsers, editors) so
  their settings apply. The Safari settings only take effect if the terminal
  has Full Disk Access. `dotfiles --no-configuration` skips it entirely.
- **`bin/`** — besides `dotfiles` (and its `lib/`), a few tools on the `PATH`:
  - `disk-cleanup` reclaims space from regenerable caches (stale JetBrains IDE
    data, package-manager caches, old Claude Code transcripts). Dry run by
    default; `--apply` deletes.
  - `claude-export-skills` zips the Claude Code skills (including the plugin's)
    for uploading to claude.ai.
  - `openstack` runs the OpenStack CLI from its own venv, which you create
    once: `uv venv ~/.venvs/openstack && uv pip install --python ~/.venvs/openstack python-openstackclient`.
- `curlrc` and `wgetrc`.

### SSH

`ssh/config` is linked to `~/.ssh/config` and includes every file in
`~/.config/dotfiles/ssh/`, the private overlay. Put one file per host or domain
there; they are backed up with the overlay, never published here. (Host files
in the old `ssh/config.d/` are moved there on the next `dotfiles` run.)

Agent forwarding is off by default: anyone with root on a host you connect to
can use a forwarded agent. Turn it on per host with `ForwardAgent yes` in that
host's file. Keys are never part of this repository.

### Claude Code

`claude/` holds the global (`~/.claude/`) [Claude Code](https://claude.ai/code)
setup:

- **`claude/plugin/`** is a standard Claude Code plugin, `dotfiles`: a
  `PreToolUse` env guard that makes destructive commands aimed at a non-local
  target ask first (kubectl, helm, terraform/tofu, argocd, gh, glab, git, mysql,
  psql, …), plus review, debugging and authoring skills (`/dotfiles:<name>`)
  and agents. With this checkout it is linked to `~/.claude/skills/dotfiles` and
  loaded in place, so edits here apply in the next session.
- **Next to it**, what a plugin cannot carry: the global instructions
  (`global-instructions.md` → `~/.claude/CLAUDE.md`), rules, the statusline, the
  theme, and `settings.json`, which is merged into `~/.claude/settings.json` —
  keys you set yourself are kept.
- **Plugins from marketplaces**: every plugin set to `true` under
  `enabledPlugins` in `claude/settings.json` (and in the private overlay's) is
  installed, after adding the marketplaces in `extraKnownMarketplaces`. That
  includes [context7](https://context7.com) for up-to-date library docs; it
  works without a key and reads `CONTEXT7_API_KEY` for higher limits.
  - To add a plugin **everywhere**, add it there.
  - To keep one on **a single machine**, just enable it there (`/plugin`):
    the merge never removes a key the tracked file does not name, and the
    installer only reads the tracked and overlay files.
- **MCP servers** that need local paths or keys go in the overlay's
  `claude/mcp.json`, merged into `~/.claude.json`.

How the guard works and how to extend it is in [CLAUDE.md](CLAUDE.md).

### Private overlay

`~/.config/dotfiles` (`$XDG_CONFIG_HOME/dotfiles`) is an optional directory for
what must not be public or differs per machine. Everything in it is read in
place; nothing is linked into `~`:

| File | Used for |
| --- | --- |
| `zprofile`, `zshrc`, `zpreztorc` | sourced at the end of the tracked ones: environment variables and keys, aliases, prezto overrides |
| `gitconfig` | included by `~/.gitconfig` |
| `gitauthor` | your Git identity (`user.name`, `user.email`); created on first setup |
| `tmux.conf` | sourced at the end of `~/.tmux.conf` |
| `Brewfile` | installed after the tracked one |
| `claude/settings.json` | merged after the tracked one — personal Claude Code choices such as auto permission mode, so a fork does not inherit them |
| `claude/mcp.json` | MCP servers with local paths or keys, merged into `~/.claude.json` |
| `claude/skills/<name>/` | private skills, linked into `~/.claude/skills` one by one |
| `ssh/` | SSH host files, included by `~/.ssh/config` |
| `secrets.env` | keys, sourced after `zprofile`; **never backed up** |

#### Backup and restore

`dotfiles` offers once per machine to back the overlay up to a **private
repository of its own**, named `dotfiles-overlay-<id>`: the hardware serial on
a Mac, the first 12 characters of `/etc/machine-id` on Linux. One repository per
machine, because every machine has its own `zprofile`, Git identity and
settings, and a shared one would have them pushing into the same files. The
description names the host and model, so the list stays readable.

- **Forges:** GitHub (`gh`), GitLab (`glab`), Gitea / Forgejo (`tea`) — the
  repository is created with the CLI, which asks you to log in if needed — or
  any git URL of a private repository you created yourself.
- **A reinstall** of the same machine finds its own repository and clones it.
- **A new machine** has none yet, so it lists your other `dotfiles-overlay-*`
  repositories and copies the one you pick into its own new repository, or
  starts empty.
- **At the end of every run**, if anything in the overlay changed, it shows
  `git status` and asks before committing and pushing. `--yes` never answers
  that question; `DOTFILES_OVERLAY_PUSH=1` does.
- `--no-overlay` skips both. Declined once, it is offered again on the next
  run.

For unattended runs, `DOTFILES_OVERLAY_FORGE` (`github`, `gitlab`, `gitea` or
`url`), `DOTFILES_OVERLAY_URL` and `DOTFILES_OVERLAY_RESTORE_FROM` (a clone URL,
or `none`) answer the questions instead.

#### Secrets

Keys are **not** backed up, not even to the private repository. They live in
`secrets.env` (mode 600), which the overlay's `.gitignore` excludes and which
`dotfiles` refuses to push if it is ever tracked. Every run moves
`export <NAME>_API_KEY|_TOKEN|_SECRET|_PASSWORD|_PAT=…` lines out of the
overlay's `zprofile`, `zshrc` and `zpreztorc`, and keys of the same shape out of
MCP server `env` blocks in `claude/mcp.json`, into it — so a key pasted into
the wrong file never reaches a commit. MCP servers get the key from the
environment Claude Code is started in; the live `~/.claude.json` keeps the value
it already had.

On a new machine, re-enter them in `secrets.env` — or have it read them from
1Password: `export CONTEXT7_API_KEY="$(op read 'op://…')"`.

An older layout (`~/.dotfiles-private`, `~/.zprofile.local`, `~/.gitauthor`,
…) is moved here automatically on the next `dotfiles` run.

### Packages

macOS packages are declared in two files, installed with `brew bundle` in this
order: [`Brewfile`](Brewfile) for what every machine gets, then the private
overlay's `~/.config/dotfiles/Brewfile` for what only this machine needs (for
me: OrbStack, UTM, Dropbox, dotnet, zig, WireGuard, the Contabo and Hetzner
CLIs). `brew bundle check --verbose` shows what is missing. To see what is
installed but declared in neither, pass both files, or `cleanup --force`
uninstalls this machine's own packages:
`brew bundle cleanup --file=<(cat ~/.dotfiles/Brewfile ~/.config/dotfiles/Brewfile)`.
An app that is
already in `/Applications` is adopted rather than reinstalled. Highlights of
the shared one: the Kubernetes and infrastructure CLIs the Claude Code guard
covers (kubectl, helm, argocd, opentofu, ansible) plus k9s, `gh`/`glab`/`tea`,
`jq`, `uv`, `bats-core` for
the test suite, cmux and iTerm2, Claude and Codex, Brave, Firefox Developer
Edition, Chrome and Edge, AltTab and AppCleaner, and Xcode, Keynote, Numbers
and Pages from the App Store.

On Linux only the basics in [`packages/linux.txt`](packages/linux.txt) are
installed (bash, curl, git, jq, tmux, zsh), with apt, dnf, apk or pacman.
Homebrew is deliberately not used there: it does not run on Alpine at all. If
zsh is not your login shell yet, `install.sh` prints the `chsh` line.

JavaScript tools come from the Brewfile where Homebrew has them; for the rest
use bun instead of npm (`bunx <tool>` for a one-off, `bun add -g` for a keeper,
which lands in `~/.bun/bin` on the `PATH`).

### VS Code

VS Code is set up by its own Settings Sync (GitHub account), not by this
repository: sign in via Accounts → Backup and Sync Settings… to get
extensions, settings, keybindings and snippets back. Extensions are therefore
not in the Brewfile — two owners would reinstall what the other removed.

## Tests

The test suite pins the behaviour of the Claude Code env guards:

```sh
bats claude/plugin/tests/guards.bats
```

Run it after any change under `claude/plugin/hooks/`. The installer scripts are
POSIX sh; check them with `shellcheck -s sh`, and try the Linux path in a
container (both described in [CLAUDE.md](CLAUDE.md)).

## Credits

To all the authors of the tools that are used by dotfiles and all the other
dotfiles repositories.

## License

Non-third-party files are licensed under the WTFPL+; see [LICENSE](LICENSE).
Bundled submodules and third-party code keep their own licenses.
