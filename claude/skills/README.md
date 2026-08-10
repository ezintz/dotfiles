# Claude Code skills

Claude Code discovers user skills at `~/.claude/skills/<name>/SKILL.md`, one level
deep. That directory is **not** a symlink to this one — instead `mirror_skills` in
`bin/dotfiles` links each skill individually, so three tiers can coexist:

| Tier    | Lives in                                  | Shared how                           |
| ------- | ----------------------------------------- | ------------------------------------ |
| public  | `~/.dotfiles/claude/skills/<name>/`       | pushed to `ezintz/dotfiles` (public) |
| local   | `~/.claude/skills/<name>/` (a real dir)   | nowhere — this machine only          |

`mirror_skills` links tiers 1 and 2 into `~/.claude/skills` and prunes links whose
source has gone away. A real directory always wins over a link, so a local skill is
never clobbered by a tracked one of the same name.

**This repository is public.** Anything placed here is world-readable once pushed.
Keep employer-internal detail — hostnames, project keys, customer names, internal
process — in the private overlay or the local tier.

## Adding a skill

Public (shared on GitHub):

```sh
mv ~/.claude/skills/<name> ~/.dotfiles/claude/skills/<name>
ln -fsn ~/.dotfiles/claude/skills/<name> ~/.claude/skills/<name>
```

Private (needs `~/.dotfiles-private` — clone it as a private repo first):

```sh
mkdir -p ~/.dotfiles-private/claude/skills
mv ~/.claude/skills/<name> ~/.dotfiles-private/claude/skills/<name>
ln -fsn ~/.dotfiles-private/claude/skills/<name> ~/.claude/skills/<name>
```

Local: just leave the directory in `~/.claude/skills/`. Nothing to do.

Either way, `dotfiles --no-packages --no-sync` re-runs the linking on any machine.

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
