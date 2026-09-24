# dotfiles-claude-plugin

A [Claude Code](https://claude.ai/code) plugin, `dotfiles`: an env guard that
makes destructive commands aimed at a non-local target ask first, plus review,
debugging and authoring skills. It is the Claude Code part of my
[dotfiles](https://github.com/ezintz/dotfiles), usable on its own.

```sh
claude plugin marketplace add ezintz/dotfiles-claude-plugin
claude plugin install dotfiles@ezintz
```

## The env guard

A `PreToolUse` hook on the Bash tool. When a command would change something
that is not on this machine — a Kubernetes context, a Terraform workspace, a
database host, a protected branch, a GitHub repository — it returns
`permissionDecision: "ask"`, and the prompt names the target the command
actually resolves to. Everything else, including read-only commands against
those same targets, runs under your normal permission mode.

It covers `kubectl`, `helm`, `terraform`/`tofu`, `openstack`, `argocd`, `git`,
`gh`, `glab`, `mysql` and `psql`, and the wrappers `ansible`, `helmfile`,
`terragrunt` and `skaffold`. It reads through `sh -c`, `eval`, heredocs piped
into a shell or `ssh`, scripts the command runs, and `make` recipes. Routine
collaboration — opening and commenting on PRs, pushing your own branch — never
prompts: a guard that asks all the time gets approved without reading.

It needs `/bin/bash` and `jq`. Without `jq` it cannot classify a command, so it
asks for anything that names one of the tools above.

**Per-project allowlist:** `~/.claude/guard-allow.conf`, one rule per line,
`<project dir> | <binary> | <target glob> | <action glob>`:

```
~/work/acme-api | mysql | host bench-db.internal* | *
```

Inside that checkout, SQL against the benchmark database runs unprompted, while
every other host still asks. The file is ignored unless you own it.

## Skills

Namespaced as `/dotfiles:<name>`:

| Skill | For |
| --- | --- |
| `debugging` | systematic root-cause debugging |
| `skill-reviewer` | reviewing a skill against Anthropic's authoring guidance |
| `rule-reviewer` | reviewing `.claude/rules/` files |
| `session-learnings` | an end-of-work pass that records durable lessons |
| `macos-process-measurement` | measuring how much CPU a process really uses on macOS, for benchmarks and before/after comparisons |
| `claude-settings-sync` | comparing `~/.claude/settings.json` with the dotfiles copy (only useful with the dotfiles) |

## Development

```sh
bats tests/guards.bats
claude plugin validate . --strict
```

Profiles live in `hooks/guards/<tool>.guard`; adding a tool is one new file.
How the guard is built and what every rule in it protects against is in
[CLAUDE.md in the dotfiles](https://github.com/ezintz/dotfiles/blob/main/CLAUDE.md#claude-code-configuration-claude).
Bump `version` in `.claude-plugin/plugin.json` with every change: installed
copies only update when it moves.

## License

[WTFPL+](LICENSE).
