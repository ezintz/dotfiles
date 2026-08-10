#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive Argo CD (`argocd`) CLI commands.
#
# Argo CD has no local-safe target — every Argo CD instance drives real
# clusters (Preview/Release/Staging/Production class) and `argocd app sync`
# deploys immediately — so every state-mutating command gets permissionDecision
# "ask". Read-only commands (get/list/history/diff/manifests/logs/version/...)
# pass through to the normal permission flow. The detected target (--core
# kube-context, --server / ARGOCD_SERVER, or the current CLI context) is
# surfaced in the reason so it can be sanity-checked before approving.
#
# The verb is looked for among *positional* words only, so an app named
# `my-app-set` or `--revision sync-test` no longer trips the guard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

cmd=$(guard_input_command) || exit 0
[ -n "$cmd" ] || exit 0

# Destructive / mutating action verbs used across `argocd <group> <verb>`
# subcommands (app/appset/proj/repo/repocreds/cluster/cert/account/gpg/admin
# all share this verb set).
ARGOCD_DESTRUCTIVE='sync|rollback|create|delete|delete-resource|patch|patch-resource|set|unset|edit|add|add-tls|add-ssh|rm|remove|rotate-auth|update-password|generate-token|delete-token|terminate-op|run|import|apply|prune|unset-credentials'
# Read-only verbs — a read verb found before a destructive word wins.
ARGOCD_READONLY='get|list|ls|history|diff|manifests|logs|wait|resources|version|context|login|logout|relogin|can-i|export|describe|status'
# Boolean flags that must not swallow the following word.
ARGOCD_BOOLS='--core|--insecure|--plaintext|--grpc-web|--port-forward|--debug|--refresh|--hard-refresh|--prune|--dry-run|--local|--upsert|--force|--yes|--cascade|--watch|--all'

action=""

classify() {
  guard_is_help && return 1
  # Dry runs preview only and don't persist changes (e.g. `argocd app sync
  # --dry-run`). Decided per invocation, not for the whole command line: in
  # `argocd app sync app --dry-run && argocd app sync app` the second sync is a
  # real deploy, and a `$cmd`-wide grep would let it through on the first one's
  # flag.
  guard_dry_run '--dry-run|--dry-run=.*' && return 1
  guard_positionals "$ARGOCD_BOOLS"
  local verb
  verb=$(guard_pos_match "${ARGOCD_DESTRUCTIVE}|${ARGOCD_READONLY}") || return 1
  [[ "$verb" =~ ^($ARGOCD_DESTRUCTIVE)$ ]] || return 1
  action="$verb"
  return 0
}

# seg_target <segment> — the Argo CD instance the *classified invocation* talks
# to, read per segment for the same reason the dry-run flag is: `argocd --server
# staging.example.com app get x && argocd --server prod.example.com app sync x`
# syncs production, and a whole-command grep would name staging in the prompt
# that approves it.
#
# `--core` talks to the cluster directly via the kube context; otherwise the
# Argo CD API server (--server / ARGOCD_SERVER) or the current CLI context
# (from the argocd config file) is the target.
seg_target() {
  local seg="$1" kctx server cfg ctx
  if printf '%s' "$seg" | grep -qE -- '(^|[[:space:]])--core([[:space:]]|$)'; then
    KUBECTL="$(command -v kubectl || echo /opt/homebrew/bin/kubectl)"
    kctx=$("$KUBECTL" config current-context 2>/dev/null || true)
    printf 'core mode -> kube-context %s' "${kctx:-unknown}"
    return 0
  fi
  server=$(printf '%s' "$seg" | grep -oE -- '--server[= ][^[:space:]]+' | head -n1 | sed -E 's/^--server[= ]//' | tr -d '"'"'"'')
  if [ -z "$server" ]; then
    server=$(printf '%s' "$seg" | grep -oE '(^|[;&|[:space:]])ARGOCD_SERVER=[^[:space:]]+' | head -n1 | sed -E 's/.*ARGOCD_SERVER=//' | tr -d '"'"'"'')
  fi
  # An inherited ARGOCD_SERVER points the CLI just as the flag does.
  [ -n "$server" ] || server="${ARGOCD_SERVER:-}"
  if [ -n "$server" ]; then
    printf 'server=%s' "$server"
    return 0
  fi
  # Fall back to current-context from the argocd config file
  # (--config overrides the default location).
  cfg=$(printf '%s' "$seg" | grep -oE -- '--config[= ][^[:space:]]+' | head -n1 | sed -E 's/^--config[= ]//' | tr -d '"'"'"'')
  [ -n "$cfg" ] || cfg="${ARGOCD_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/argocd/config}"
  ctx=""
  if [ -r "$cfg" ]; then
    ctx=$(grep -E '^current-context:' "$cfg" 2>/dev/null | head -n1 | sed -E 's/^current-context:[[:space:]]*//' | tr -d '"'"'"'')
  fi
  printf 'context=%s' "${ctx:-unknown}"
}

# Each mutating segment is judged — and named — on its own target.
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  guard_reaches argocd "$seg" || continue
  classify || continue
  target=$(seg_target "$seg")
  guard_ask "Destructive argocd \"$action\" targets $target. Argo CD has no local-safe target (drives real clusters; sync deploys immediately); explicit user confirmation required."
done <<EOF
$(guard_segments "$cmd")
EOF

exit 0
