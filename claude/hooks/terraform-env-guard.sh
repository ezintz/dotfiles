#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive Terraform / OpenTofu commands.
#
# Terraform has no reliable "local" target (no --context equivalent), so every
# state-mutating command gets permissionDecision "ask". Read-only commands
# (plan/validate/show/output/fmt/graph/console/state list|show|pull/...) pass
# through to the normal permission flow. The detected workspace / -chdir /
# -var-file are surfaced in the reason so the target can be sanity-checked
# before approving. See guard-lib.sh for how the subcommand is identified.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

cmd=$(guard_input_command) || exit 0
[ -n "$cmd" ] || exit 0

# Known subcommands, both classes — first exact token match wins, so
# `terraform show apply.tfplan` reads as `show`, not `apply`.
TF_VOCAB='init|validate|plan|show|output|fmt|graph|console|providers|version|help|test|metadata|get|login|logout|apply|destroy|import|taint|untaint|refresh|force-unlock|state|workspace'
TF_DESTRUCTIVE='apply|destroy|import|taint|untaint|refresh|force-unlock'
TF_VALFLAGS='-var|-var-file|-state|-state-out|-backup|-target|-replace|-out|-lock-timeout|-parallelism|-backend-config|-plugin-dir|-from-module'

bin=""
action=""

classify() {
  guard_is_help && return 1
  guard_subcommand "$TF_VOCAB" "$TF_VALFLAGS" || return 1
  local a1
  case "$GUARD_SUB" in
    state)
      a1=$(guard_arg_at 1 "$TF_VALFLAGS")
      case "$a1" in
        rm|mv|push|replace-provider) action="state $a1" ;;
        *) return 1 ;;                                   # list/show/pull read
      esac ;;
    workspace)
      a1=$(guard_arg_at 1 "$TF_VALFLAGS")
      case "$a1" in
        delete) action="workspace delete" ;;
        *) return 1 ;;                                   # list/show/select/new
      esac ;;
    init)
      # Plain init is safe; a backend migration rewrites remote state.
      if guard_has_token '-migrate-state|-force-copy'; then
        action="init (backend migration)"
      else
        return 1
      fi ;;
    *)
      [[ "$GUARD_SUB" =~ ^($TF_DESTRUCTIVE)$ ]] || return 1
      action="$GUARD_SUB" ;;
  esac
  return 0
}

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  if guard_reaches terraform "$seg"; then
    classify && { bin="terraform"; break; }
  fi
  if guard_reaches tofu "$seg"; then
    classify && { bin="tofu"; break; }
  fi
done <<EOF
$(guard_segments "$cmd")
EOF

[ -n "$bin" ] || exit 0

BIN_PATH="$(command -v "$bin" || echo "/opt/homebrew/bin/$bin")"

# Target signals from the command itself.
chdir=$(printf '%s' "$cmd"    | grep -oE -- '-chdir=[^[:space:]]+' | head -n1 | sed 's/^-chdir=//' | tr -d '"'"'"'')
varfiles=$(printf '%s' "$cmd" | grep -oE -- '-var-file[= ][^[:space:]]+' | sed -E 's/^-var-file[= ]//' | tr -d '"'"'"'' | paste -sd, -)
tfws=$(printf '%s' "$cmd"     | grep -oE '(^|[;&|[:space:]])TF_WORKSPACE=[^[:space:]]+' | head -n1 | sed -E 's/.*TF_WORKSPACE=//' | tr -d '"'"'"'')

# Resolve the effective workspace: TF_WORKSPACE wins, else ask terraform/tofu.
ws="$tfws"
if [ -z "$ws" ]; then
  if [ -n "$chdir" ]; then
    ws=$("$BIN_PATH" -chdir="$chdir" workspace show 2>/dev/null || true)
  else
    ws=$("$BIN_PATH" workspace show 2>/dev/null || true)
  fi
fi

target="workspace=${ws:-unknown}"
[ -n "$chdir" ]    && target="$target, dir=$chdir"
[ -n "$varfiles" ] && target="$target, var-file=$varfiles"

guard_ask "Destructive $bin \"$action\" ($target). Terraform has no local-safe target; explicit user confirmation required."
