
# This shell

Bash tool calls run through zsh with a prezto config that is deployed to every
machine, and two of its settings fail in the direction that looks like success:

- **`>` will not overwrite.** `unsetopt CLOBBER` is set, so redirecting onto an
  existing file fails with "file exists" and leaves the *old* file in place —
  the regenerated output never appears and everything downstream reads stale
  data. Use `>|` to truncate on purpose.
- **`cp`, `mv` and `rm` are aliased to `-i`.** An overwrite or delete waits for a
  y/n that a scripted call never sends, so it either hangs until the tool times
  out or counts as declined and the file is silently left untouched. Prefix with
  `command` to bypass the alias: `command mv -f old new`.

Neither reports failure the way a normal error does, so when a command was meant
to replace or delete something, verify the result rather than trusting that it
ran.

# Git

- **Use three dots, not two, against a base branch.** `git diff main...HEAD`
  diffs against the merge-base (where this branch actually forked from) —
  the same thing `gh pr diff` and `glab mr diff` compute.

# Guarded tools

`kubectl`, `helm`, `terraform`/`tofu`, `openstack`, `argocd`, `git`, `gh`,
`glab`, `mysql` and `psql` are gated by a PreToolUse hook
(`~/.claude/hooks/env-guard.sh`). It
decides what needs confirmation when the command runs, and its behaviour is
pinned by tests, so what it catches is not restated here. Three things it
cannot see:

- **A different binary.** `helmfile`, `terragrunt`, `make deploy`,
  `ansible-playbook` and similar wrappers run the guarded tool out of a config
  file the hook never reads: nothing fires and nothing warns. Invoke the guarded
  binary directly. Transparent composition is read correctly and needs no
  avoiding — `timeout`, `watch`, `xargs`, pipes, subshells, `&&`/`;` chains, and
  scripts the command executes.
- **A target selected earlier in the same call.** `kubectl config use-context
  prod && kubectl delete …` is resolved against the context current *now*, so the
  prompt names the wrong cluster — worse than no prompt at all. Same for
  `terraform workspace select` and `argocd context`. One operation per Bash call.
- **A target you never named.** Pass `--context` / `--kube-context` / `-chdir=` /
  `--os-cloud` / `--server` / `-h` explicitly, even when the active one is
  already correct, so the prompt shows something verifiable instead of ambient
  state. Never point `KUBECONFIG=` or `--kubeconfig` at an alternate config file.

Read-only inspection is never gated — use it freely, in any context. Writing a
command is not running it, so a destructive example in a runbook or heredoc is
fine. If something read-only does prompt, that is a guard bug worth reporting;
never restructure a command to dodge a prompt.

A target that genuinely is disposable — a benchmark database, a kind cluster —
can be pre-approved in `~/.claude/guard-allow.conf`, one machine-wide file
whose rules each name the project they apply to. That file is the user's:
suggest a rule for it, never write or edit one yourself.
