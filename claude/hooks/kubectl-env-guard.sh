#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive kubectl/helm commands targeting any non-local context.
#
# Local contexts (allowlist below) pass through to the normal permission flow.
# Everything else — including unknown contexts and custom kubeconfigs — gets
# permissionDecision "ask" so the user must explicitly approve.
set -u

KUBECTL="$(command -v kubectl || echo /opt/homebrew/bin/kubectl)"
JQ="$(command -v jq || echo /usr/bin/jq)"

input=$(cat)
cmd=$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Mutating / destructive verbs per tool
KUBECTL_DESTRUCTIVE='delete|apply|create|patch|edit|replace|scale|autoscale|expose|run|set|rollout|drain|cordon|uncordon|taint|label|annotate|cp|exec'
HELM_DESTRUCTIVE='install|upgrade|uninstall|delete|rollback|test'

tool=""
# kubectl/helm invocation: start of command, after a separator, absolute path,
# or inside quotes (sh -c "kubectl ...", bash -c 'helm ...')
if printf '%s' "$cmd" | grep -qE '(^|[;&|(/"'"'"'[:space:]])kubectl([[:space:]]|$)' \
   && printf '%s' "$cmd" | grep -qE "kubectl[^;&|()]*[[:space:]](${KUBECTL_DESTRUCTIVE})([[:space:]\"']|\$)"; then
  tool="kubectl"
elif printf '%s' "$cmd" | grep -qE '(^|[;&|(/"'"'"'[:space:]])helm([[:space:]]|$)' \
   && printf '%s' "$cmd" | grep -qE "helm[^;&|()]*[[:space:]](${HELM_DESTRUCTIVE})([[:space:]\"']|\$)"; then
  tool="helm"
fi
[ -n "$tool" ] || exit 0

# Dry runs don't persist changes (kubectl: client-side only; helm: any --dry-run)
if [ "$tool" = "kubectl" ]; then
  printf '%s' "$cmd" | grep -q -- '--dry-run=client' && exit 0
else
  printf '%s' "$cmd" | grep -q -- '--dry-run' && exit 0
fi

if printf '%s' "$cmd" | grep -qE -- '--kubeconfig|(^|[;&|[:space:]])KUBECONFIG='; then
  # Custom kubeconfig (flag or env prefix): context detection is unreliable,
  # treat as non-local
  ctx="(custom kubeconfig)"
else
  # 1) explicit context flag (kubectl: --context, helm: --kube-context),
  # 2) in-command `use-context` switch, 3) fall back to the current context
  ctx=$(printf '%s' "$cmd" | grep -oE -- '--(kube-)?context[= ][^[:space:]]+' | head -n1 | sed -E 's/^--(kube-)?context[= ]//' | tr -d '"'"'"'')
  if [ -z "$ctx" ]; then
    ctx=$(printf '%s' "$cmd" | grep -oE 'use-context[[:space:]]+[^[:space:]]+' | head -n1 | awk '{print $2}')
  fi
  if [ -z "$ctx" ]; then
    ctx=$("$KUBECTL" config current-context 2>/dev/null || true)
  fi
fi

LOCAL_CONTEXTS='^(orbstack|docker-desktop|docker-for-desktop|minikube|kind(-[A-Za-z0-9_.-]+)?|k3d-[A-Za-z0-9_.-]+|rancher-desktop|colima)$'
if printf '%s' "$ctx" | grep -qE "$LOCAL_CONTEXTS"; then
  exit 0
fi

"$JQ" -cn --arg tool "$tool" --arg ctx "${ctx:-unknown}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: ("Destructive " + $tool + " command targets NON-LOCAL context \"" + $ctx + "\" (Preview/Release/Staging/Production class). Explicit user confirmation required.")
  }
}'
