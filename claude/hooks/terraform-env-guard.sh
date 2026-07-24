#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive Terraform / OpenTofu commands.
#
# Terraform has no reliable "local" target (no --context equivalent), so every
# state-mutating command gets permissionDecision "ask". Read-only commands
# (plan/validate/show/output/fmt/graph/console/state list|show/...) pass through
# to the normal permission flow. The detected workspace / -chdir / -var-file are
# surfaced in the reason so the target can be sanity-checked before approving.
set -u

JQ="$(command -v jq || echo /usr/bin/jq)"

input=$(cat)
cmd=$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Destructive / state-mutating top-level subcommands.
TF_DESTRUCTIVE='apply|destroy|import|taint|untaint|refresh|force-unlock'

# terraform/tofu invocation: start of command, after a separator, absolute path,
# or inside quotes (sh -c "terraform ...").
bin=""
if printf '%s' "$cmd" | grep -qE '(^|[;&|(/"'"'"'[:space:]])terraform([[:space:]]|$)'; then
  bin="terraform"
elif printf '%s' "$cmd" | grep -qE '(^|[;&|(/"'"'"'[:space:]])tofu([[:space:]]|$)'; then
  bin="tofu"
fi
[ -n "$bin" ] || exit 0

# Decide destructiveness. `[[:space:]]verb` requires a real space before the
# verb, so `plan -destroy` (read-only destroy plan) does NOT match `destroy`.
destructive=""
action=""
if printf '%s' "$cmd" | grep -qE "${bin}[^;&|()]*[[:space:]](${TF_DESTRUCTIVE})([[:space:]\"']|\$)"; then
  destructive="yes"
  action=$(printf '%s' "$cmd" | grep -oE -- "[[:space:]](${TF_DESTRUCTIVE})([[:space:]\"']|\$)" | head -n1 | tr -d "[:space:]\"'")
elif printf '%s' "$cmd" | grep -qE "${bin}[^;&|()]*[[:space:]]state[[:space:]]+(rm|mv|push|replace-provider)([[:space:]\"']|\$)"; then
  destructive="yes"
  action="state $(printf '%s' "$cmd" | grep -oE -- '[[:space:]]state[[:space:]]+(rm|mv|push|replace-provider)' | head -n1 | awk '{print $2}')"
elif printf '%s' "$cmd" | grep -qE "${bin}[^;&|()]*[[:space:]]workspace[[:space:]]+delete([[:space:]\"']|\$)"; then
  destructive="yes"
  action="workspace delete"
fi
[ -n "$destructive" ] || exit 0

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

"$JQ" -cn --arg tool "$bin" --arg act "${action:-command}" --arg tgt "$target" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Destructive " + $tool + " \"" + $act + "\" (" + $tgt + "). Terraform has no local-safe target; explicit user confirmation required.")
  }
}'
