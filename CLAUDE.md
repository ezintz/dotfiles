# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A macOS-first dotfiles repository (the installer also runs on Linux servers) that manages shell configuration (Zsh/Prezto), Git, SSH, Tmux, macOS defaults and a Claude Code plugin. The main mechanism is symlinking files from this repo into `~`.

## Installation & Usage

```bash
# Fresh machine (Mac or server): gets the CLT/Homebrew or git it needs first
curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/install.sh | sh

# Re-run after changes
bin/dotfiles
bin/dotfiles --no-packages       # skip Brewfile / Linux packages
bin/dotfiles --no-sync           # skip git pull
bin/dotfiles --no-links          # skip symlinks and the git identity prompt
bin/dotfiles --no-configuration  # skip macOS defaults
bin/dotfiles --no-overlay        # skip creating/restoring and backing up the overlay repo
bin/dotfiles --yes               # answer every prompt except "restart now?" and pushes
bin/dotfiles --dry-run           # print what would change
```

After setup, `bin/` is in PATH (via `zprofile`), so `dotfiles` works as a command from anywhere.

`install.sh`, `bin/dotfiles`, `bin/lib/*.sh` and `bin/_macos` are **POSIX sh**, because that is the only shell on both a fresh Mac and a Debian/Alpine server — zsh, which `bin/dotfiles` used to be written in, is absent from the latter. Two traps only show under dash/busybox, never under macOS `sh` (which is bash), so a Mac-only test passes them: `&>` backgrounds the command instead of redirecting it, and a failed redirection on a *special* builtin (`:`, `.`, `exec`, …) exits the whole script. Check changes with

```bash
uv run --with shellcheck-py shellcheck -s sh -x -P bin/lib install.sh bin/dotfiles bin/lib/*.sh bin/_macos
```

and exercise the Linux path in a container: copy the checkout to `/root/.dotfiles` in `debian:stable-slim` and `alpine` and run `sh /root/.dotfiles/install.sh --yes --no-sync`.

The one test suite is `claude/plugin/tests/guards.bats`, which pins
the behaviour of the Claude Code env guards:

```bash
bats claude/plugin/tests/guards.bats   # bats-core is in the Brewfile
```

Run it after any change under `claude/plugin/hooks/`.

Most cases are behavioural (this command passes, that one asks). The last three
are different: they scrape `kubectl`/`helm`/`tofu --help` for the tool's real
subcommand list and fail if any verb is missing from that guard's
`GUARD_VOCAB`. A verb the guard has never heard of matches nothing, so the
segment is skipped and silently treated as read-only — the one failure a
hand-written case can't reach, because you can't test for a verb you don't know
exists. They `skip` when the binary isn't installed, and fail if the scrape
returns implausibly few verbs, so a stale parser can't make them vacuous.
Keep them working rather than deleting them when they go red.

## Architecture

### Symlink Strategy

`bin/dotfiles` symlinks files directly into `~`. For example:
- `git/gitconfig` → `~/.gitconfig` (also gitignore, gitattributes; `gitk` and `tigrc` are tracked but not linked)
- `ssh/config` → `~/.ssh/config`
- `tmux/tmux.conf` → `~/.tmux.conf`

`.zshrc` is a special case: it is only symlinked if `~/.zshrc` does not already exist, allowing machine-local shell config to live there without being overwritten.

Editing files in this repo immediately affects the live configuration.

The checkout must live at `~/.dotfiles`: the prezto runcoms, `tmux.conf` and the Claude session hooks all name that path, so `install.sh` lets a fork override the remote but not the location.

The private overlay is `$XDG_CONFIG_HOME/dotfiles` (`~/.config/dotfiles`, `DOTFILES_LOCAL_DIRECTORY`): `zprofile`, `zshrc`, `zpreztorc`, `gitconfig`, `gitauthor`, `tmux.conf`, `Brewfile`, `claude/settings.json`, `claude/mcp.json`, `claude/skills/<name>/`. The tracked config reads each file **in place** — nothing is linked into `~` — which is why the paths are spelled out in the prezto runcoms, `git/gitconfig` and `tmux/tmux.conf`: git and tmux expand `~` but not `$XDG_CONFIG_HOME`, so they use the XDG default literally. `ssh/` and the untracked `secrets.env` complete the list; ssh, like git and tmux, gets the literal path. `migrate_overlay` moves the old layout (`~/.dotfiles-private`, `~/.<name>.local`, `~/.gitauthor`, host files in `ssh/config.d/`) there once.

The run order in `bin/dotfiles` is: `migrate_overlay` → sync (this repo, then the overlay if it is a checkout) → tracked packages → `setup_overlay` → the overlay's `Brewfile` → links and Claude → `setup_git` → `bin/_macos` → `backup_overlay`. Each position is load-bearing: `setup_overlay` needs `gh`/`glab`/`tea` from the tracked Brewfile, and has to restore the overlay before its Brewfile, settings and `gitauthor` are read; `backup_overlay` runs last so it sees the `gitauthor` that `setup_git` just wrote.

**Overlay backup** (`bin/lib/overlay.sh`). One private repo **per machine**, `dotfiles-overlay-<id>` — the Mac's hardware serial, or the first 12 characters of `/etc/machine-id` on Linux, where the serial needs root — because every machine has its own `zprofile` and `gitauthor`, and a shared repo would have them all writing the same files. A new machine has no repo yet, so it is offered the others (`forge_list`, filtered by the prefix) to seed from; seeding copies files in and never overwrites. Each forge is one `case` arm in `forge_ready`/`forge_url`/`forge_list`/`forge_create`; `url` is the fallback for a repo the user created, and it is also how to test the whole flow without a forge: point `DOTFILES_OVERLAY_FORGE=url DOTFILES_OVERLAY_URL=` at a local `git init --bare` repo in a sandbox `HOME`. Run such a test against a **copy** of this checkout — `migrate_overlay` moves untracked host files out of the repo it runs from. The push at the end goes through `ask`, never `confirm`: `--yes` is for routine questions, and publishing is not one.

**Keys never enter the overlay repo.** `migrate_overlay_secrets` runs from `migrate_overlay` and again right before each commit, and moves `export` lines whose name matches `SECRET_NAME_RE` out of the overlay's rc files, and matching keys out of MCP `env` blocks in `claude/mcp.json`, into `secrets.env` (mode 600, in the overlay's `.gitignore`, sourced by the prezto `zprofile`). Running it before the commit, not only at the start, is what catches a key pasted in during the same run. `backup_overlay` additionally refuses outright if `secrets.env` is ever tracked. A key whose name does not fit the pattern is not caught — widen `SECRET_NAME_RE` rather than special-casing a file.

### Shell Configuration (Prezto)

`prezto/` is a git submodule pointing to a custom fork (`github.com/ezintz/prezto`). Runtime configs live in `prezto/runcoms/`:
- `zpreztorc` — which Prezto modules are loaded (the main file to edit for shell behavior)
- `zprofile` — PATH, environment variables, tool integrations (OrbStack, krew, kubeconfig)
- `zshrc` — minimal: sources `tmux/cmux.zsh` from this repo (a no-op outside cmux), then Prezto init

The overlay's `zprofile` and then its `secrets.env` are sourced at the end of `zprofile` (likewise `zshrc`/`zpreztorc` for theirs) — machine-specific env vars go in the overlay, keys in `secrets.env`, never in this repo.

### Modular SSH Config

`ssh/config` includes all files from `~/.config/dotfiles/ssh/*` — per-host or per-domain configs live in the private overlay and are backed up with it, never in this public repo. `ssh/config.d/` is gitignored only so a stale checkout's host files cannot be added by accident; `migrate_ssh_hosts` moves them out. `ForwardAgent` is deliberately not set globally; a host file turns it on.

### macOS System Defaults

`bin/_macos` is a standalone script (~850 lines) that sets macOS defaults for Dock, Finder, Safari, etc. `bin/dotfiles` runs it as `sh bin/_macos` in its own process, never sources it, so it is POSIX sh like the rest.

### Git Submodules

- `prezto` — Zsh framework (custom fork)
- `claude/plugin` — the Claude Code plugin, see below
- `tmux/plugins/tmux-resurrect` — saves and restores tmux sessions across reboots; loaded directly by `tmux.conf`, there is no plugin manager

After cloning, run `git submodule update --init --recursive`. `bin/dotfiles` syncs the two that are committed to from here, prezto and the plugin, with `sync_own_submodule`, which fast-forwards them on their branch rather than running `submodule update`: an update detaches the submodule, and the next commit made inside it is then on no branch.

### Claude Code Configuration (`claude/`)

`claude/` manages the *global* (`~/.claude/`) Claude Code setup, not project-local config. Most of it is a standard Claude Code **plugin**, `claude/plugin/` (name `dotfiles`): the env-guard hook, skills, agents and refs. It is a **submodule**, its own public repository [`ezintz/dotfiles-claude-plugin`](https://github.com/ezintz/dotfiles-claude-plugin), which is also the `ezintz` marketplace (`.claude-plugin/marketplace.json` there, with `"source": "./"`), so `claude plugin marketplace add ezintz/dotfiles-claude-plugin` does not clone these dotfiles. Its unpublished skills, refs and agents are listed in the plugin's own `.gitignore`: loaded here because the checkout is linked in place, never pushed, and absent from a fresh clone, so they only exist on the machine that has them. Plugin skills are namespaced, so `debugging` is `/dotfiles:debugging`. A plugin cannot ship rules, a CLAUDE.md, permissions, env, a statusline or arbitrary settings, so those stay directly in `claude/` and are linked or merged by `bin/lib/claude.sh`.

**How the plugin is loaded differs by machine, on purpose.** With this checkout, `bin/dotfiles` links `claude/plugin` to `~/.claude/skills/dotfiles`, where Claude Code loads it *in place* as `dotfiles@skills-dir` — edits are live next session. Installing from the marketplace instead **copies** it into `~/.claude/plugins/cache/`, even from a local-directory marketplace (verified), so never enable `dotfiles@ezintz` on a machine that has the checkout: every skill would load twice and the guard would run twice. A change to the plugin is committed and pushed **in the submodule** (`git -C claude/plugin`), with `version` in its `.claude-plugin/plugin.json` bumped — marketplace users receive an update only when it moves — and then the new submodule pointer is committed here, as for prezto. Check the manifests with `claude plugin validate ./claude/plugin --strict`, and `claude plugin details dotfiles@skills-dir` shows what actually loaded. The plugin's history before the split lives in this repository under `claude/hooks`, `claude/skills` and `claude/plugin`; `git subtree split` only follows a directory, so the new repository starts at the move.

- `global-instructions.md` → symlinked to `~/.claude/CLAUDE.md`. It is named differently in-repo on purpose, so Claude Code's auto-discovery doesn't also load it a second time as a project file when working inside this dotfiles repo. **It costs context in every session of every repo**, so it holds only things that change how Claude behaves *anywhere* — command discipline, tool usage. How something here is built, tested or extended is maintenance knowledge and belongs in this file instead; it is loaded automatically whenever the work is actually happening in this repo. When in doubt: would this help in an unrelated repo six months from now? If not, it goes here.
- `plugin/hooks/` — the PreToolUse env guard, registered by the plugin's `hooks/hooks.json` as `/bin/bash "${CLAUDE_PLUGIN_ROOT}/hooks/env-guard.sh"` (explicit `/bin/bash`, so it neither depends on the exec bit surviving install nor picks up a newer bash): destructive commands aimed at a non-local target get `permissionDecision: "ask"` instead of running under the ambient permission mode.
  - `env-guard.sh` is the **only** registered `PreToolUse` hook. (`SessionStart`/`SessionEnd` run `tmux/claude-session.sh`, which has nothing to do with guarding — see Terminals.) It reads the tool JSON once and dispatches to every profile in `hooks/guards/*.guard`. One process per Bash call instead of one per guarded tool (~13ms vs ~141ms when nothing matches).
  - `guard-lib.sh` holds the command-line parsing — segmentation, wrapper/`eval` detection, exact-token subcommand matching, flag-value skipping. This is the part that keeps `helm template test chart` from reading as `helm test`.
  - **Writing ≠ executing.** Heredoc bodies are stripped before classification (`guard_strip_heredocs`), so `cat > runbook.md <<EOF … kubectl --context production delete … EOF` documents a command without prompting. The line that *opens* the heredoc is kept, because `kubectl apply -f - <<EOF` really does apply. Three things survive the strip, because they are execution and not writing. **Who consumes the body decides what it is**: `bash <<'EOF'` and `ssh host <<'EOF'` are scripts arriving on stdin, not documents, so `guard_heredoc_script_bodies` classifies them like a script file and the prompt names the real target — stripping them as data made both completely silent. `GUARD_HEREDOC_SHELL_HEADS` is the consumer list; `GUARD_HEREDOC_TRANSPORTS` (docker, podman, nerdctl, lima, colima, kubectl) are transport rather than consumers, since `docker exec -i box bash <<EOF` runs the body in a shell named later on the line. A data consumer (`cat`, `tee`, `git commit -F -`) leaves it data however suggestively it reads. Then, with an **unquoted** delimiter the shell still expands the body, so `guard_heredoc_expansions` pulls each `$( )`/backtick substitution back out as its own segment — it classifies with a real resolved target, and prose in the body is untouched because prose is not a substitution. And any body, quoted or not, that hands a guarded binary to an interpreter's exec API (`subprocess`, `os.system`, `system(`, `sh -c`, …) asks via `guard_heredoc_shells_out`: the body is opaque, so the prompt names the binary rather than a target it cannot read. Naming a binary in data (`name: kubectl-helper`) trips none of the three, since it is neither a substitution nor an exec call and `cat`/`tee` is not a consumer that runs anything. Note the pre-filter haystack in `env-guard.sh` includes the stripped body for exactly this reason — filter on the segments alone and the shell-out net is never reached. Conversely `guard_script_bodies` reads the contents of scripts the command executes (`bash deploy.sh`, `./deploy.sh`, `source x.sh`) — one level deep, bounded to 4 files × 64 KiB — so a destructive command is caught when it runs from a file, not when it is written to one. `guard_make_recipes` does the same for `make <target>`: it reads the target's recipe out of the Makefile and classifies *that*, so `make test` that deletes a namespace asks and `make deploy` that only rsyncs does not. Bounded to 4 targets, one level deep, with no variable expansion — a recipe of `$(KUBECTL) delete` is not seen, which is what the `make` entries in `settings.json` `permissions.ask` back up.
  - **An inert head is a bypass.** `guard_embedded_invocation` skips segments headed by something that only prints or searches, but `find`, `sed`, `awk`, `fd` and `xargs` each run a command built from their own arguments (`find … -exec`, GNU `sed '1e cmd'`, `awk '{system(…)}'`), so they are deliberately *not* on that list — and `git` is only skipped for its search subcommands, not blanket. False positives are not the risk they look like: a search pattern like `sed -n "/kubectl delete/p"` tokenizes to `delete/p`, which exact-matches nothing in any vocabulary. Separately `command` is a transparent wrapper in `guard_invocation` (`command kubectl delete` really runs kubectl); it stays on the skip list too, and `command -v helm` stays quiet because the `-*` break fires first.
  - **`guard_tokenize` strips backslashes as well as quotes.** A nested quote is routinely written escaped — `sh -c "kubectl --context prod \"delete\" pod x"` — and stripping only the quote characters leaves `\kubectl`/`\delete`, matching neither the binary nor any subcommand, so the whole invocation slips past.
  - Keep `guard_tokenize` fork-free. It runs for every segment of every command times every profile; forking `printf | tr` per token there cost ~8ms per call on its own. The same applies to anything else running per segment or per token: no `printf | tr`, and return values through a global rather than `$(…)`, since a command substitution is itself a fork.
  - **Benchmark string work under `/bin/bash`, not the Homebrew bash on `$PATH`.** The hook runs under its shebang, i.e. bash 3.2, where `${var//[chars]/}` is quadratic: stripping `;(),` from a single 9 KB word takes **44 seconds** there against 31ms under bash 5, and a `-e "delete … where id in (1,2,…,2000)"` is exactly one such word. That is not a slow hook, it is a Bash tool call that never returns. Per-character loops (`${s:$i:1}` plus `out="$out$c"`) are quadratic twice over in any bash and belong in awk. Where a scan cannot be moved out of the shell, bound the input instead — `guard_sql_destructive_word` skips tokens over 64 characters, which is free because its match is exact. `bats -f "does not hang"` pins it; a plain correctness test does not, because a statement whose verb comes first returns before it ever reaches the expensive token.
  - `guards/<tool>.guard` is a **profile**: the verb vocabulary as data, plus `guard_resolve_target()` (and optionally `guard_classify_extra()` / `guard_reason()`) as code. Currently kubectl, helm, terraform+tofu, openstack, argocd, git, gh, glab, mysql, psql, and the wrappers ansible, helmfile, terragrunt, skaffold. Files prefixed `_` are shared helpers, not profiles — the dispatcher only globs `*.guard`.
  - Three classification styles: `vocab` (fixed subcommand list, e.g. kubectl/terraform), `positional` (open-ended object-verb grammar, e.g. openstack/argocd/gh), and `sql` (mysql/psql — the verb is a SQL keyword that never appears in argv itself; `guard_classify_extra` is the whole classifier, not an override). Pick with `GUARD_STYLE`.
  - The `sql` style has to find its payload before it can classify it, and there are five channels: an `-e`/`-c` value, a herestring, a heredoc body, a file (`-f` or `<`), and **standard input from a pipe**. The pipe is the one worth naming — `mysql db < migrate.sql` and `cat migrate.sql | mysql db` are the same operation, and `guard_segments` splits on `|`, so the relationship only survives in `$GUARD_RAW_CMD`. A producer whose text the guard can read (echo/printf/cat) is scanned like any other payload; an opaque one (mysqldump, gunzip, curl, a script) asks, because a restore is not a thing to discover afterwards.
  - **Quotes are stripped only where they delimit a payload the guard extracted** — a flag value, a herestring — never blanket-fashion off a whole command line. Blanket stripping turns `-e "select … where state = 'delete'"` into a DELETE and prompts on a read. Conversely `guard_sql_unescape` collapses `\"` before extraction, or `ssh dbhost "mysql -e \"drop table t\""` matches nothing at all.
  - `guard_reconstruct_segment` repairs a segment the blind segmenter cut mid-quote, and `guard_sql_invocation_text` bounds the repair back to that one invocation. Both halves are load-bearing and they fail differently: without the repair the mutation is missed, without the bound it is *found and attributed to the wrong segment*, so the prompt names the harmless host. Test both (`psql: a mutation in a later segment is attributed to that segment`).
  - mysql/psql also override `GUARD_HELP_TOKENS`: the shared `guard_is_help` reads bare `-h` as `--help` by default, which is wrong for these two (`-h` is `--host`) and would otherwise pass a real mutation through silently. A profile whose short help flag isn't `-h` must override it.
  - **Per-project allowlist** (`guard_allowed` in `guard-lib.sh`, `~/.claude/guard-allow.conf`). A rule is `<project dir> | <binary> | <target glob> | <action glob>`, e.g. `~/work/acme-api | mysql | host bench-db.internal* | *` — inside that checkout, SQL against the throwaway benchmark database runs unprompted while `prod-db.internal` still asks. The target is matched against the *resolved* target string, i.e. the exact text the prompt would have shown, so what gets allowed is what would have been read and approved anyway; target and action globs match case-insensitively (hostnames and SQL verbs both are, and `GUARD_ACTION` echoes back whatever case the command used). Checked centrally in `env-guard.sh` right before `guard_ask`, so it covers every profile and costs a file read only when a prompt was about to fire. The file lives in `$HOME`, is read as data (never sourced), and is ignored unless the user running the hook owns it: an allowlist a session could write into the repo it is working in would be self-approval with extra steps.

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
   environment gets approved. This bug class appeared four separate times:
   `gh repo delete acme/scratch` reporting the current checkout, `git push --mirror
   backup` reporting origin, `git -C dir push` reading the `-C` value as the remote,
   and `docker exec … mysql` reporting "(remote via docker)" for a container on this
   laptop's own socket — while `DOCKER_HOST=tcp://prod:2375 docker exec …` resolved
   against the *local* default and ran in silence, because an env-assignment prefix
   made the head `prod:2375` instead of `docker`.
4. **Enumerate the exact values of a safety flag; never prefix-match.**
   `--dry-run|--dry-run=.*` matched `--dry-run=false` and waved real helm and
   argocd mutations straight through.
5. **Guard only where the decision needs runtime state** (which kube context, which
   TF workspace, which Argo CD server, which repo). For a purely syntactic rule a
   `permissions.ask` entry in `settings.json` is cheaper than a hook. A wrapper is not automatically that case: `helmfile`,
   `terragrunt`, `skaffold` and `ansible` all have a resolvable target (environment,
   working dir, inventory, kube-context) and a real verb grammar, so they earn
   profiles and let their read-only halves through. `make` is the exception — a
   target name says nothing about what it runs — so it stays a name-based
   `permissions.ask` rule, backing up the recipe expansion in `guard_make_recipes`.
6. **Add test cases in both directions** to `claude/plugin/tests/guards.bats` — the
   read-only command that must pass *and* the mutation that must still ask — and
   run `bats claude/plugin/tests/guards.bats`. Use fictional cluster/release/host names,
   never real ones.
   For a test that pins a *fix*, break the fix and watch the test fail before
   trusting it. Two of these passed against reverted code here: one because the
   `cp -i` alias silently blocked the revert (see `~/.claude/CLAUDE.md`), the
   other because the test reproduced the symptom rather than the harm — a glued
   segment is still caught by embedded-invocation detection, so the failure had
   to be pinned on the *target resolution* picking the wrong context instead. A
   green suite proves nothing about a bug it never actually reproduced.
   Anything resolved by asking a real binary (kube context, docker endpoint, TF
   workspace) needs a stub in `claude/plugin/tests/stubs/` — and the stub must be
   `chmod +x`, or `command -v` silently falls through to the real tool and the
   case passes on whatever this machine happens to be configured with.
7. **Adding a tool is one new `.guard` file** in `claude/plugin/hooks/guards/`.
   The plugin ships the directory as a whole and the hook is already registered,
   so nothing else changes — then bump the plugin `version`, commit in the
   submodule, and commit its new pointer here.
- `plugin/skills/`, `plugin/agents/`, `plugin/refs/` travel with the plugin. `refs/` holds reference docs too long to inline into a skill or rule — they aren't auto-discovered by Claude Code, so a skill links them by relative path (`../../refs/<ref-name>.md` from a `SKILL.md`, `../refs/…` from an agent), and a file a skill bundles is reached as `${CLAUDE_SKILL_DIR}/…`. Both resolve wherever the plugin is installed; `~/.claude/skills/<name>/…` does not, since plugin skills are not there. `rules/` and `themes/` stay outside the plugin and are linked **per entry**, since `~/.claude/rules` can hold rules this repo does not own. The one rule links `~/.claude/refs/knowledge-placement.md`, which `bin/dotfiles` links to the plugin's copy so rule and skills share one file.
- `settings.json` → **deep-merged** into `~/.claude/settings.json` via `jq` (`merge_json` in `bin/lib/claude.sh`), not symlinked like everything else in this repo. Tracked keys win and arrays are unioned, so deleting an array entry here never deletes it from a live file — that needs a migration like `prune_legacy_hook`. Keys that weaken safety prompts (`permissions.defaultMode`, `skip*PermissionPrompt`, `remoteControlAtStartup`) do not belong here but in `~/.config/dotfiles/claude/settings.json`, merged right after, so a fork does not inherit them. Its `permissions.ask` list covers `make`, the one wrapper with no verb grammar to classify. `ask` rules are evaluated independently of hooks and still prompt even when a hook returns `allow`, so the two layers compose rather than override each other. Rule syntax is `Bash(cmd *)` — the trailing space-star enforces a word boundary, so `Bash(ansible *)` matches `ansible` and `ansible -m ping` but not `ansible-lint`; `Bash(make deploy*)` without the space deliberately also matches `make deploy-prod`. Rules are matched against each subcommand of a compound command separately. Its `env` block pins `CLAUDE_CODE_NATIVE_CURSOR=1`: Claude Code otherwise hides the real terminal cursor and paints an inverse-video block, which no terminal setting can restyle. With the flag it positions the real cursor and never emits DECSCUSR, so the terminal's own shape and blink apply. The flag is undocumented — it is in the binary's env-var registry but not the published docs — so re-check it after a Claude Code upgrade. It is also refused while the DECSTBM scroll-region renderer is active, which is the first thing to suspect if the block cursor comes back. It also pins `CLAUDE_CODE_TMUX_TRUECOLOR=1`, because Claude Code caps itself to 256 colours whenever `$TMUX` is set — every cmux tab runs in tmux, so the cap is always on here. The symptom is not missing colour but *wrong* colour: 24-bit values are quantised to the xterm cube, so a theme's `#282C34` is painted `#5F5F5F`. It only shows up once a theme uses real hex; the `ansi:` names in the stock `dark-ansi` theme survive the cap untouched, which is why this sat unnoticed. To check it, `tmux capture-pane -p -e` the pane and count `48;2;` against `48;5;` — under the cap there are no `48;2;` at all.
- `mcp.json` → **deep-merged** into `~/.claude.json`, not `~/.claude/settings.json` — user-scope MCP servers live in a different file from every other Claude setting here, which is the only reason this needs saying. It is optional and absent from this checkout; `merge_json` skips a missing source. `~/.config/dotfiles/claude/mcp.json` is merged after it, for servers that carry local paths or keys (CodeGraphContext). A hosted server that has an official plugin belongs in `enabledPlugins` instead, with its key in the environment: context7 is `context7@claude-plugins-official`, reading `CONTEXT7_API_KEY` from the overlay's `secrets.env`. A key never goes into either file: the server reads it from the environment, exported by `secrets.env`.
- `statusline-command.sh` → symlinked to `~/.claude/statusline-command.sh`.
- `themes/onedark.json` → `~/.claude/themes/onedark.json`, selected by `"theme": "custom:onedark"` in `settings.json`. Its `base` is `dark-ansi`, and that choice is load-bearing in both directions. Three separate things in Claude Code branch on whether the theme identifier contains `"ansi"`: the colour mode for the diff renderer, the syntax highlighting theme, and the diff syntax scheme. On an ansi base all three read the terminal palette, so inline code and code blocks are One Dark Pro. On a `dark` base they are hardcoded instead — code blocks become Monokai, and inline code becomes `#B1B9F9`, a violet belonging to no palette here. That colour is **not reachable from this file**: it is read from the base theme rather than the merged overrides, verified by setting `permission`, `suggestion` and `remember` to a probe value and watching the probe land elsewhere while inline code never moved. Choosing the base is the only control over it.
  The price of the ansi base is that hex fed to the diff renderer is quantised to the 256-colour cube, so a fill must be a cube entry that maps to itself. `#2E4433` and `#53353D` do not — they land on `(0,95,95)` teal and `(95,95,95)` grey, which is what "the diff is cyan and grey" means. `ansi:green`/`ansi:red` survive but are bright fills that leave the row text at **1.06:1**. The six diff fills are two hue ramps, each a 135-level row over a 95-level partner: `#008700`/`#005F00` and `#870000`/`#5F0000`, cube entries 28/22 and 88/52. The 95-level entry serves as both the word fill and the dimmed fill, so a highlighted word reads as the same colour going darker rather than a different colour entirely. The rows cost different amounts of text contrast — 2.21:1 added against 4.85:1 removed — because green carries 3.4x red's luminance weight at the same channel value; the added row is the deliberate end of that trade, chosen over a darker `#005F00` row because the cube has no green below 95 to pair it with, only black. An earlier revision of this file claimed no usable green existed at all; that was an artifact of demanding 4.5:1 on a fill sitting behind body text, and it is the reason the base was wrong for a while.
  Everything not fed to the diff renderer keeps exact truecolor hex on either base — the panel fills render as written, confirmed by `48;2;66;72;84` and `48;2;40;44;52` in a pane capture. Two traps when editing. An override naming a token the base lacks is **silently dropped**, so verify a new key against the base rather than trusting a clean start. `diffAddedWord` and `diffRemovedWord` are word-level **fills** painted over the row fill, so they carry the row's text — which the renderer emits as bare `ESC[37m`, i.e. palette 7 (`#ABB2BF`), never a theme token. Tuned as foregrounds they were `#98C379`/`#E06C75`, which quantise to `#87D787` and `#DF8787`: light blocks under light text, at **1.23:1** and **1.28:1**. A word fill has to go *darker* than its row, not brighter — only 22 cube entries clear 3.2:1 against `#ABB2BF` at all, and every one of them is dark. `composerSidebarBackground` (the changes pane) is the pane colour `#21252B` rather than a lighter panel shade: with `background-opacity-cells` in `ghostty/config` a fill is exactly as translucent as the window, so any other colour shows as a tinted block. Raising it again means re-checking the four real fills against it, since a fill tuned only against the pane can disappear on a lighter one. Claude Code's `/theme` editor writes a theme back by renaming a temp file over it, which replaces the symlink with a regular file — a theme tweaked in the UI detaches from this repo until `bin/dotfiles` re-links it.

`bin/claude-export-skills` is a separate utility (not run by `bin/dotfiles`) that zips up `~/.claude/skills/*` and the skills of plugins linked there (`~/.claude/skills/*/skills/*`) for uploading to claude.ai.

### Package Definitions

macOS packages are in `Brewfile`, installed with `brew bundle` (`HOMEBREW_CASK_OPTS=--adopt`, so an app already in `/Applications` is taken over rather than failing the bundle), then the overlay's `Brewfile` for packages only one machine needs. A package belongs in the tracked file when this repo's own config uses or configures it, or every machine should have it; one machine's tools go in its overlay. `brew bundle check --verbose` lists what is missing. `brew bundle cleanup` must be given **both** files (`--file=<(cat Brewfile ~/.config/dotfiles/Brewfile)`): against the tracked one alone it lists the machine's own packages as undeclared, and `--force` uninstalls them. Linux servers get only `packages/linux.txt` (bash, curl, git, jq, tmux, zsh — names identical across apt, dnf, apk and pacman); not Homebrew, which needs glibc and so cannot run on Alpine. There is no npm list: a JavaScript tool Homebrew packages goes in the Brewfile, and anything else is bun's job (`bunx`, or `bun add -g` into `~/.bun/bin`). VS Code extensions are deliberately absent from the Brewfile: VS Code Settings Sync owns them, and two owners would reinstall what the other removed.

**Claude Code plugins have no list of their own**: `install_claude_plugins` installs every `enabledPlugins` entry set to `true` in the tracked and private `settings.json`, after `marketplace add` for each `extraKnownMarketplaces` entry — a fresh HOME knows no marketplace, and `plugin install` then fails with "not found". A second list would drift from the key Claude Code actually reads. It is additive, like `brew bundle` without `cleanup`.

### Terminals

Two terminal apps are configured here, by two different mechanisms:

- `iterm2/` holds the preferences plist and the OneDark color scheme. `bin/_macos` sets `LoadPrefsFromCustomFolder` and points `PrefsCustomFolder` at this directory, so iTerm2 reads the tracked plist at launch **and writes back into it** — changes made in the preferences GUI land in the working tree, mixed in with keys iTerm2 maintains on its own (saved prompts, workgroups). Expect unrelated churn when diffing it.
- `ghostty/` holds the config cmux renders with. cmux is a native app embedding libghostty and deliberately surfaces no font or cursor settings of its own, so everything about how a cmux pane looks is in `ghostty/config`; cmux's own settings are in `cmux/cmux.json` (JSONC, validated by the `$schema` it names) and cover only app behaviour: shortcuts, sidebar colours, notifications. Unlike the iTerm2 plist both are symlinked (per file, from `bin/dotfiles`), so cmux's "Open Ghostty Settings" command edits the repo copy directly. Most of `cmux.json` is the commented-out template cmux generates listing every setting with its default; only the uncommented blocks at the bottom are live.

Every cmux tab runs inside its own tmux session, so shells and whatever runs in them (Claude Code included) survive cmux quitting, and tmux-resurrect brings them back after a reboot. `tmux/cmux.zsh`, sourced from the top of the prezto `zshrc`, does it; its comments carry the reasons. Claude Code comes back as the exact conversation, not the newest one in the directory: `tmux/claude-session.sh`, run from Claude's `SessionStart`/`SessionEnd` hooks and resurrect's save/restore hooks, keeps the conversation id per pane. Two settings elsewhere depend on this: `terminal.autoResumeAgentSessions` stays `false` in `cmux/cmux.json`, or cmux would start a second Claude next to the one tmux kept alive, and `tmux.conf` saves on a timer and on detach instead of using tmux-continuum, whose status-line trigger never fires with the status line off. To test a change to `cmux.zsh` without quitting cmux, open a throwaway workspace (`cmux new-workspace --focus false`, then `cmux select-workspace` it once — terminals in a workspace nobody has shown do not start) and inspect `tmux ls`.

Both terminals carry the same OneDark palette — `ghostty/config` and, in `iterm2/com.googlecode.iterm2.plist`, **three** copies of every colour key: the `Default` profile, the `tmux` profile (`bin/_macos` sets `TmuxUsesDedicatedProfile`, so tmux-integration sessions read that one), and the `OneDark` custom preset. They must move together or tmux sessions end up a different colour from everything else. `iterm2/OneDark.itermcolors` is a fourth copy, importable but never read at runtime. Two slots deliberately differ from what was originally imported; `ghostty/config` carries the reasoning at the palette block. Edit the plist only while iTerm2 is **not running**, or it writes its in-memory preferences back over the file on quit and the change vanishes with no error. Its components are float32 widened to double (`118/255` is stored as `0.46274510025978088`), so a value computed in double precision will not match and a search-and-replace will silently find nothing; `Only The Default BG Color Uses Transparency` is `true`, so iTerm2 applies transparency to the window background alone and keeps panel fills painted by a TUI opaque. Ghostty deliberately differs: `background-opacity-cells = true` makes those fills translucent too, because Claude Code's changes pane is a fill the theme cannot remove, only recolour to match the window.

The cursor is a blinking underscore, and four surfaces have to agree for that to hold, because each can override the one before it: the iTerm2 profiles (`Cursor Type = 0`, `Blinking Cursor`), `ghostty/config`, `tmux/tmux.conf`, and Claude Code's `env` block above. Ghostty's shell integration is the non-obvious one — left enabled it re-emits a DECSCUSR blinking bar at every prompt redraw, which is why `ghostty/config` disables just that feature.

### Git Identity

`git/gitconfig` includes the overlay's `gitauthor` for user name and email; `setup_git` in `bin/dotfiles` creates it interactively on first setup.
