# Kubernetes / Helm command discipline

Destructive kubectl/helm commands on non-local clusters are gated by a PreToolUse hook
(`~/.claude/hooks/kubectl-env-guard.sh`). Run cluster commands so the hook can always
see the true target:

- Invoke `kubectl` and `helm` **directly** in the Bash tool — never through wrapper
  scripts, `eval`, Makefile targets, or tools like helmfile/skaffold/argocd that hide
  the target cluster from the command text.
- Always pass the target **explicitly**: `--context <name>` for kubectl,
  `--kube-context <name>` for helm — even when the current context would already be
  correct. Never rely on whatever context happens to be active.
- One cluster operation per Bash call. Do not chain `kubectl config use-context` with
  a mutating command, and do not batch mutations across environments in one command.
- Never set `KUBECONFIG=` or `--kubeconfig` to point at alternate config files.
- Only the local cluster (context `orbstack`) may be mutated without user confirmation.
  Treat every other context — including unfamiliar ones — as production-class: prefer
  `--dry-run` first, and never attempt to rephrase or restructure a command to avoid
  the confirmation prompt.
