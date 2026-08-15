
# Git

- **Use three dots, not two, against a base branch.** `git diff main...HEAD`
  diffs against the merge-base (where this branch actually forked from) —
  the same thing `gh pr diff` and `glab mr diff` compute.

# Kubernetes / Helm command discipline

Destructive kubectl/helm commands on non-local clusters are gated by a PreToolUse hook
(`~/.claude/hooks/env-guard.sh`). Run cluster commands so the hook can always
see the true target:

- Invoke `kubectl` and `helm` **directly** in the Bash tool — never through wrapper
  scripts, Makefile targets, or tools like helmfile/skaffold/ansible that hide the
  command in a file the hook cannot read. Transparent composition is fine and is
  classified precisely: `timeout`, `watch`, `nice`, `nohup`, `xargs`, pipes, loops,
  subshells, `&&`/`;` chains and multi-line scripts.
- Running kubectl/helm on another machine or in a container (`ssh host "kubectl …"`,
  `docker run … kubectl …`) always requires confirmation: the local context says
  nothing about what it will actually hit.
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
- Read-only inspection is never gated — use it freely: `kubectl get/describe/logs/top/
  diff/events/explain/auth can-i`, `kubectl rollout status|history`, `kubectl cp
  pod:/path ./local`, any `--dry-run`, and `helm template/lint/show/get/list/history/
  status/diff`. If one of these does prompt, that is a guard bug — report it instead
  of working around it.
- `kubectl exec` passes only for a strict read-only payload (`cat`, `ls`, `ps`, `df`,
  `grep`, `find` without `-delete`/`-exec`, …). Shells, interpreters and DB clients
  always ask, as do readers given an operand that makes them act (`env <cmd>`,
  `hostname <name>`, `date <time>`). Do not try to phrase a write as a read.

# Terraform / OpenTofu command discipline

Destructive `terraform`/`tofu` commands are gated by a PreToolUse hook
(`~/.claude/hooks/env-guard.sh`). Terraform has no local-safe target, so
**every** state-mutating command (`apply`, `destroy`, `import`, `refresh`, `taint`,
`state rm|mv|push`, `workspace delete`, `force-unlock`, `init -migrate-state`)
requires confirmation.

- Invoke `terraform` and `tofu` **directly** in the Bash tool — never through
  `terragrunt`, Makefile targets, wrapper scripts, or `eval`. Wrappers hide the
  operation from the hook and it will not fire.
- Make the target **visible** in the command: pass `-chdir=<dir>`, name the
  `-var-file=<env>.tfvars`, and select the workspace explicitly (`TF_WORKSPACE=<ws>`
  or a preceding `workspace select`) so the environment is obvious before applying.
- One operation per Bash call. Do not chain `workspace select` with a mutating
  command, and do not batch operations across environments/directories.
- Always run `plan` before `apply`, and inspect it. Read-only commands
  (`plan` incl. `-destroy`, `validate`, `show`, `output`, `fmt`, `graph`, `providers`,
  `state list|show|pull`, `workspace list|select`, plain `init`) are safe and pass
  through — use them freely to inspect before mutating.
- Never add `-auto-approve` to dodge the prompt, and never restructure a command to
  avoid the confirmation. Treat every workspace as production-class.

# OpenStack command discipline

Destructive `openstack` CLI commands are gated by a PreToolUse hook
(`~/.claude/hooks/env-guard.sh`). OpenStack has no local-safe target
(every configured cloud is a real environment), so **every** mutating command
(`create`, `delete`, `set`, `reboot`, `rebuild`, `resize`, `migrate`, `shelve`,
`suspend`, `stop`, `lock`, `rescue`, `evacuate`, `attach`/`detach`, etc.)
requires confirmation.

- Invoke `openstack` **directly** in the Bash tool — never through wrapper
  scripts, Ansible, Heat CLI wrappers, or `eval` that hide the target cloud
  from the command text.
- Always pass the target **explicitly**: `--os-cloud <name>` — even when
  `OS_CLOUD` is already exported. Never rely on whatever cloud happens to be
  active in the shell.
- One operation per Bash call. Do not chain cloud selection with a mutating
  command, and do not batch mutations across clouds/environments.
- Read-only commands (`list`, `show`, `find`) are safe and pass through — use
  them freely to inspect before mutating.
- Never restructure a command to avoid the confirmation prompt. Treat every
  cloud (staging, quality, production, internal, etc.) as production-class.

# Argo CD command discipline

Destructive `argocd` CLI commands are gated by a PreToolUse hook
(`~/.claude/hooks/env-guard.sh`). Argo CD has no local-safe target
(every Argo CD instance drives real clusters, and `argocd app sync` deploys
immediately), so **every** state-mutating command (`app sync`, `app delete`,
`app rollback`, `app set`/`unset`, `app patch`/`patch-resource`/`delete-resource`,
`app actions run`, `proj`/`repo`/`cluster`/`cert`/`account` create/delete/add/rm/set,
etc.) requires confirmation.

- Invoke `argocd` **directly** in the Bash tool — never through wrapper scripts,
  Makefile targets, CI wrappers, or `eval` that hide the target from the command
  text.
- Make the target **visible** in the command: pass `--server <host>` (or run in
  `--core` mode against an explicit kube-context) rather than relying on whatever
  `argocd context` happens to be current. The hook surfaces the detected
  server/context/kube-context in its prompt — sanity-check it before approving.
- One operation per Bash call. Do not chain `argocd context <name>` (or a
  `--server` switch) with a mutating command, and do not batch mutations across
  environments.
- Read-only commands (`app get`/`list`/`history`/`diff`/`manifests`/`logs`,
  `version`, and `app sync --dry-run`) are safe and pass through — use them
  freely to inspect before mutating.
- Never restructure a command to avoid the confirmation prompt. Treat every
  Argo CD instance and every managed cluster as production-class.

# Writing a command vs. running it

All of the guards above distinguish the two, so write freely and don't
restructure to dodge a prompt:

- **Writing is not running.** Heredoc bodies are never classified — documenting
  `kubectl --context production delete …` in a runbook, README or script does not
  prompt. Neither does any file edit; the guards only see Bash.
- **Running from a file is still running.** The guard reads the contents of
  scripts a command executes (`bash deploy.sh`, `./deploy.sh`), so moving a
  mutation into a script does not get it past the guard.
