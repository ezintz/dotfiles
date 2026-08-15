# Shared target resolution for the kubectl and helm profiles. Not a profile
# itself (the dispatcher only globs *.guard), sourced by both.

# guard_resolve_target — the kube context the *current segment* targets.
# Read per segment, never off the whole command line: a command line can carry
# more than one context, and taking the first match approves the production
# apply on the strength of the local one.
guard_resolve_target() {
  local seg="$GUARD_SEG" ctx kubectl_bin
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
    ctx=$(printf '%s' "$GUARD_CMD" | grep -oE 'use-context[[:space:]]+[^[:space:]]+' | head -n1 | awk '{print $2}')
  fi
  if [ -z "$ctx" ]; then
    kubectl_bin="$(command -v kubectl || echo /opt/homebrew/bin/kubectl)"
    ctx=$("$kubectl_bin" config current-context 2>/dev/null || true)
  fi
  printf '%s' "$ctx"
}

guard_reason() {
  printf 'Destructive %s "%s" targets NON-LOCAL context "%s" (Preview/Release/Staging/Production class). Explicit user confirmation required.' \
    "$GUARD_BIN" "$GUARD_ACTION" "${1:-unknown}"
}

# Clusters that only ever exist on this laptop. Everything else — including
# unknown contexts and custom kubeconfigs — has to be confirmed.
GUARD_KUBE_LOCAL_CONTEXTS='^(orbstack|docker-desktop|docker-for-desktop|minikube|kind(-[A-Za-z0-9_.-]+)?|k3d-[A-Za-z0-9_.-]+|rancher-desktop|colima)$'
