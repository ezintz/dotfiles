# Skills

These skills ship in the `dotfiles` Claude Code plugin (`claude/plugin/`), so
they are namespaced: `debugging` is invoked as `/dotfiles:debugging`. On a
machine with this checkout, `bin/dotfiles` links the whole plugin to
`~/.claude/skills/dotfiles`, where Claude Code loads it in place as
`dotfiles@skills-dir` and an edit here is live in the next session. Elsewhere
it is installed from the `ezintz` marketplace:
`claude plugin marketplace add ezintz/dotfiles && claude plugin install dotfiles@ezintz`.

There are three places a skill can live:

| Tier    | Lives in                                      | Shared how                           |
| ------- | --------------------------------------------- | ------------------------------------ |
| public  | `~/.dotfiles/claude/plugin/skills/<name>/`    | in the plugin, pushed to `ezintz/dotfiles` (public) |
| private | `~/.config/dotfiles/claude/skills/<name>/`    | private overlay repo; linked one by one into `~/.claude/skills` |
| local   | `~/.claude/skills/<name>/` (a real dir)       | nowhere — this machine only          |

A skill directory that is listed in `.gitignore` here is still loaded from
this checkout, but never reaches anyone installing the plugin from GitHub.

**This repository is public.** Anything placed here is world-readable once pushed.
Keep employer-internal detail — hostnames, project keys, customer names, internal
process — in the private overlay or the local tier.

## Adding a skill

Public (in the plugin):

```sh
mv ~/.claude/skills/<name> ~/.dotfiles/claude/plugin/skills/<name>
```

Private (needs the overlay `~/.config/dotfiles` — ideally a private repo):

```sh
mkdir -p ~/.config/dotfiles/claude/skills
mv ~/.claude/skills/<name> ~/.config/dotfiles/claude/skills/<name>
dotfiles --no-packages --no-sync --no-configuration   # links it back
```

Local: just leave the directory in `~/.claude/skills/`. Nothing to do.

A file a skill bundles is reached through `${CLAUDE_SKILL_DIR}` (its own
directory), and a shared doc through `../../refs/<name>.md`; both resolve
wherever the plugin is installed. `~/.claude/skills/<name>/…` does not, since
plugin skills are not there.

## Creating a skill

`claude/settings.json` force-enables Anthropic's `skill-creator` plugin through
`enabledPlugins`, so it is available on every machine without an interactive
`/plugin install`. It carries the authoring loop — intent interview, draft, eval
harness with baseline comparison, and a description-triggering optimiser — so
prefer it over hand-rolling a `SKILL.md`.

## Reviewing a skill

The `skill-reviewer` skill checks a `SKILL.md` against Anthropic's published
guidance — frontmatter, description length, scope, and hardcoded credentials or
absolute paths. Run it before promoting a skill to the public tier.
