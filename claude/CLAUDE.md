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

# Terraform / OpenTofu command discipline

Destructive `terraform`/`tofu` commands are gated by a PreToolUse hook
(`~/.claude/hooks/terraform-env-guard.sh`). Terraform has no local-safe target, so
**every** state-mutating command (`apply`, `destroy`, `import`, `refresh`, `taint`,
`state rm|mv|push`, `workspace delete`, `force-unlock`) requires confirmation.

- Invoke `terraform` and `tofu` **directly** in the Bash tool — never through
  `terragrunt`, Makefile targets, wrapper scripts, or `eval`. Wrappers hide the
  operation from the hook and it will not fire.
- Make the target **visible** in the command: pass `-chdir=<dir>`, name the
  `-var-file=<env>.tfvars`, and select the workspace explicitly (`TF_WORKSPACE=<ws>`
  or a preceding `workspace select`) so the environment is obvious before applying.
- One operation per Bash call. Do not chain `workspace select` with a mutating
  command, and do not batch operations across environments/directories.
- Always run `plan` before `apply`, and inspect it. Read-only commands
  (`plan`, `validate`, `show`, `output`, `fmt`, `state list|show`) are safe and pass
  through — use them freely to inspect before mutating.
- Never add `-auto-approve` to dodge the prompt, and never restructure a command to
  avoid the confirmation. Treat every workspace as production-class.
