#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive kubectl/helm commands targeting any non-local context.
#
# Local contexts (allowlist below) pass through to the normal permission flow.
# Everything else — including unknown contexts and custom kubeconfigs — gets
# permissionDecision "ask" so the user must explicitly approve.
#
# Read-only work is never gated: `kubectl get/describe/logs/diff/rollout status`,
# `helm template/lint/show/diff/get`, `--dry-run`, `--help` and reads via
# `kubectl cp pod:/path ./local` or `kubectl exec … -- cat` all pass through.
# See guard-lib.sh for how the subcommand is identified.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

KUBECTL="$(command -v kubectl || echo /opt/homebrew/bin/kubectl)"

cmd=$(guard_input_command) || exit 0
[ -n "$cmd" ] || exit 0

# --- vocabularies -----------------------------------------------------------

# Known subcommands, both classes. The first exact token match wins, so
# read-only subcommands shield everything after them (`helm template test …`
# is a template render, not `helm test`).
KUBECTL_VOCAB='get|describe|logs|top|explain|api-resources|api-versions|version|help|cluster-info|config|auth|diff|events|wait|port-forward|proxy|completion|options|plugin|kustomize|alpha|convert|delete|apply|create|patch|edit|replace|scale|autoscale|expose|run|set|rollout|drain|cordon|uncordon|taint|label|annotate|cp|exec|attach|debug|certificate|evict'
KUBECTL_DESTRUCTIVE='delete|apply|create|patch|edit|replace|scale|autoscale|expose|run|set|rollout|drain|cordon|uncordon|taint|label|annotate|cp|exec|attach|debug|certificate|evict|auth'
# Flags that consume the following word (booleans must NOT be listed here —
# that would let a destructive subcommand hide behind a flag).
KUBECTL_VALFLAGS='-n|--namespace|--context|--cluster|--user|--kubeconfig|--as|--as-group|--as-uid|--token|--server|-s|--request-timeout|--cache-dir|--certificate-authority|--client-certificate|--client-key|--tls-server-name|--username|--password|-f|--filename|-k|--kustomize|-o|--output|-l|--selector|--field-selector|-c|--container|--image|-v|--v|--chunk-size|--profile|--profile-output|--log-flush-frequency'

HELM_VOCAB='template|lint|show|get|list|ls|status|history|search|version|help|env|repo|dependency|dep|pull|fetch|package|verify|inspect|diff|plugin|completion|docs|create|registry|push|cm-push|mapkubeapis|schema|unittest|install|upgrade|uninstall|delete|rollback|test'
HELM_DESTRUCTIVE='install|upgrade|uninstall|delete|rollback|test'
HELM_VALFLAGS='--kube-context|-n|--namespace|--kubeconfig|-f|--values|--set|--set-string|--set-json|--set-file|--set-literal|--repo|--version|-o|--output|--show-only|-s|--description|--post-renderer|--post-renderer-args|--timeout|--burst-limit|--qps|-a|--api-versions|--kube-apiserver|--kube-token|--kube-as-user|--kube-as-group|--kube-ca-file|--kube-tls-server-name|--registry-config|--repository-config|--repository-cache|--ca-file|--cert-file|--key-file|--username|--password|--keyring|--output-dir|--release-name'

# Commands that only read inside a container, for `kubectl exec … -- <cmd>`.
# Deliberately excludes anything with a write mode (shells, interpreters,
# redis-cli/mongosh/psql, nc, tee, ip/ifconfig, nvidia-smi) — an unknown
# payload always asks. Allowlist alone is not enough: several of these have a
# second personality, so each risky one carries an argument policy below.
EXEC_READONLY='cat|ls|dir|env|printenv|id|whoami|pwd|hostname|date|uptime|df|du|free|ps|top|head|tail|wc|stat|uname|nproc|md5sum|sha1sum|sha256sum|cksum|netstat|ss|nslookup|dig|host|getent|ping|traceroute|find|grep|egrep|fgrep|which|readlink|realpath|file|strings|lsof|vmstat|iostat|mpstat|pg_isready'
# Commands that only read when given no operand. With one they do something
# else entirely: `env FOO=1 rm -rf /` runs rm, `hostname box` renames the host,
# `date "2020…"` sets the clock. Flags are fine (`uname -a`, `date -u`).
EXEC_OPERAND_FREE='env|printenv|hostname|id|whoami|pwd|uptime|uname|nproc|free|date'
# Per-command flags that turn a reader into a writer.
EXEC_FIND_UNSAFE='-delete|-exec|-execdir|-ok|-okdir|-fprint|-fprintf|-fls'
EXEC_DATE_UNSAFE='-s|--set|--set-time'
EXEC_SS_UNSAFE='-K|--kill'

# --- classify ---------------------------------------------------------------

tool=""
action=""

# exec_payload_reads <command> <index-in-GUARD_ARGS>
# 0 when the payload of `kubectl exec … -- <command> …` can only read.
# Deny-by-default: no payload, an unknown command, a shell, an interpreter or
# a pipeline the pod's shell would expand all fall through to "ask".
exec_payload_reads() {
  local cmd="$1" idx="$2" i n t
  [ -n "$cmd" ] && [ "$idx" -ge 0 ] || return 1
  [[ "$cmd" =~ ^($EXEC_READONLY)$ ]] || return 1

  # guard_has_flag, not guard_has_token: `date --set=2026-01-01` sets the clock
  # in a pod that holds CAP_SYS_TIME just as `date --set 2026-01-01` does.
  case "$cmd" in
    find) guard_has_flag "$EXEC_FIND_UNSAFE" && return 1 ;;
    date) guard_has_flag "$EXEC_DATE_UNSAFE" && return 1 ;;
    ss|netstat) guard_has_flag "$EXEC_SS_UNSAFE" && return 1 ;;
  esac

  if [[ "$cmd" =~ ^($EXEC_OPERAND_FREE)$ ]]; then
    # Any operand (a non-flag word) means it is running or setting something.
    n=${#GUARD_ARGS[@]}
    i=$((idx + 1))
    while [ $i -lt $n ]; do
      t="${GUARD_ARGS[$i]}"
      case "$t" in -*) ;; *) return 1 ;; esac
      i=$((i + 1))
    done
  fi
  return 0
}

classify_kubectl() {
  guard_is_help && return 1
  guard_subcommand "$KUBECTL_VOCAB" "$KUBECTL_VALFLAGS" || return 1
  [[ "$GUARD_SUB" =~ ^($KUBECTL_DESTRUCTIVE)$ ]] || return 1

  local a1 a2
  case "$GUARD_SUB" in
    rollout)
      # status/history only read; restart/undo/pause/resume mutate.
      a1=$(guard_arg_at 1 "$KUBECTL_VALFLAGS")
      case "$a1" in status|history) return 1 ;; esac
      action="rollout ${a1:-?}" ;;
    auth)
      # `auth can-i` / `auth whoami` read; `auth reconcile` writes RBAC.
      a1=$(guard_arg_at 1 "$KUBECTL_VALFLAGS")
      case "$a1" in reconcile) action="auth reconcile" ;; *) return 1 ;; esac ;;
    apply)
      a1=$(guard_arg_at 1 "$KUBECTL_VALFLAGS")
      case "$a1" in view-last-applied) return 1 ;; esac
      action="apply" ;;
    cp)
      # Download (pod:path -> local) reads; upload (local -> pod:path) writes.
      a1=$(guard_arg_at 1 "$KUBECTL_VALFLAGS")
      a2=$(guard_arg_at 2 "$KUBECTL_VALFLAGS")
      if [ -n "$a1" ] && [ -n "$a2" ] \
         && [ "${a1#*:}" != "$a1" ] && [ "${a2#*:}" = "$a2" ]; then
        return 1                                   # pod -> local, read-only
      fi
      action="cp (upload into pod)" ;;
    exec)
      # `exec … -- <read-only cmd>` inspects; anything else can change state.
      local i=0 n=${#GUARD_ARGS[@]} payload="" pidx=-1
      while [ $i -lt $n ]; do
        if [ "${GUARD_ARGS[$i]}" = "--" ] && [ $((i + 1)) -lt $n ]; then
          pidx=$((i + 1)); payload="${GUARD_ARGS[$pidx]##*/}"; break
        fi
        i=$((i + 1))
      done
      if exec_payload_reads "$payload" "$pidx"; then return 1; fi
      action="exec ${payload:+-- $payload}" ;;
    *)
      action="$GUARD_SUB" ;;
  esac
  return 0
}

classify_helm() {
  guard_is_help && return 1
  guard_subcommand "$HELM_VOCAB" "$HELM_VALFLAGS" || return 1
  [[ "$GUARD_SUB" =~ ^($HELM_DESTRUCTIVE)$ ]] || return 1
  action="$GUARD_SUB"
  return 0
}

# --- dry runs ---------------------------------------------------------------
# kubectl: --dry-run, --dry-run=client and --dry-run=server never persist
# (=none does). helm: any --dry-run only renders.
KUBECTL_DRY_RUN='--dry-run|--dry-run=client|--dry-run=server'
HELM_DRY_RUN='--dry-run|--dry-run=.*'

LOCAL_CONTEXTS='^(orbstack|docker-desktop|docker-for-desktop|minikube|kind(-[A-Za-z0-9_.-]+)?|k3d-[A-Za-z0-9_.-]+|rancher-desktop|colima)$'

# --- target context ---------------------------------------------------------

# seg_context <segment> — the context the *classified invocation* targets.
# Read per segment, never off the whole command line: `kubectl --context
# orbstack apply -f local.yml && kubectl --context production apply -f prod.yml`
# carries both, and taking the first match approves the production apply on the
# strength of the local one.
seg_context() {
  local seg="$1" ctx
  if guard_is_remote_wrapper; then
    # Runs on another host / in another container: the local kubeconfig and the
    # `orbstack` allowlist say nothing about what it will actually hit.
    printf '(remote via %s)' "$GUARD_HEAD"; return 0
  fi
  if printf '%s' "$seg" | grep -qE -- '--kubeconfig|(^|[;&|[:space:]])KUBECONFIG='; then
    # Custom kubeconfig (flag or env prefix): context detection is unreliable,
    # treat as non-local.
    printf '(custom kubeconfig)'; return 0
  fi
  # 1) explicit context flag (kubectl: --context, helm: --kube-context),
  # 2) an in-command `use-context` switch — that one is read from the whole
  #    command line because it changes what a *later* segment inherits,
  # 3) fall back to the current context.
  ctx=$(printf '%s' "$seg" | grep -oE -- '--(kube-)?context[= ][^[:space:]]+' | head -n1 | sed -E 's/^--(kube-)?context[= ]//' | tr -d '"'"'"'')
  if [ -z "$ctx" ]; then
    ctx=$(printf '%s' "$cmd" | grep -oE 'use-context[[:space:]]+[^[:space:]]+' | head -n1 | awk '{print $2}')
  fi
  if [ -z "$ctx" ]; then
    ctx=$("$KUBECTL" config current-context 2>/dev/null || true)
  fi
  printf '%s' "$ctx"
}

# Every destructive segment is paired with its own dry-run state and its own
# context before the guard decides; stopping at the first one classified would
# judge the whole command by whichever mutation happens to be written first.
while IFS= read -r seg; do
  [ -n "$seg" ] || continue

  tool=""; action=""
  if guard_reaches kubectl "$seg" && classify_kubectl; then
    tool="kubectl"
    guard_dry_run "$KUBECTL_DRY_RUN" && continue
  elif guard_reaches helm "$seg" && classify_helm; then
    tool="helm"
    guard_dry_run "$HELM_DRY_RUN" && continue
  else
    continue
  fi

  ctx=$(seg_context "$seg")
  printf '%s' "$ctx" | grep -qE "$LOCAL_CONTEXTS" && continue

  guard_ask "Destructive $tool \"$action\" targets NON-LOCAL context \"${ctx:-unknown}\" (Preview/Release/Staging/Production class). Explicit user confirmation required."
done <<EOF
$(guard_segments "$cmd")
EOF

exit 0
