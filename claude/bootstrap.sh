#!/usr/bin/env sh
#
# The Claude Code part of these dotfiles, on a machine WITHOUT the repo cloned:
#
#   curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/claude/bootstrap.sh | sh
#
# Installs:
#   the `dotfiles` plugin from the `ezintz` marketplace (this repo): the
#   env-guard PreToolUse hook, skills and agents
#   ~/.claude/CLAUDE.md                     global instructions (an existing one
#                                           is kept as CLAUDE.md.backup-<time>)
#   ~/.claude/rules/*.md, ~/.claude/refs/*.md   path-scoped rules and the refs they name
#   ~/.claude/settings.json                 marketplace, plugins and ask rules merged in
#
# Plugins cannot ship rules, global instructions or permissions, which is why
# those three are still fetched and merged here.
#
# Needs curl or wget, and jq (preinstalled on macOS 15+). Safe to re-run:
# settings are merged additively and nothing already there is dropped.
# Override the source with CLAUDE_BOOTSTRAP_BASE (e.g. to pin a branch/fork).

set -eu

BASE="${CLAUDE_BOOTSTRAP_BASE:-https://raw.githubusercontent.com/ezintz/dotfiles/main/claude}"
MARKETPLACE_REPO="${CLAUDE_BOOTSTRAP_REPO:-ezintz/dotfiles}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# A raw.githubusercontent fetch cannot list a directory, so these are explicit.
# A rule whose body points at a ref needs that ref here too, or the pointer
# lands on nothing.
RULES="knowledge-placement.md"
REFS="knowledge-placement.md"

# Everything the pre-plugin layouts copied into ~/.claude/hooks. The plugin
# brings the guard now; left in place, a stale settings.json entry would run
# the old copy as well, and a missing one fails every Bash call.
LEGACY_HOOK_FILES="env-guard.sh guard-lib.sh kubectl-env-guard.sh terraform-env-guard.sh openstack-env-guard.sh argocd-env-guard.sh"

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    echo "error: need curl or wget on PATH" >&2
    exit 1
  fi
}

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required (to merge settings.json, and by the env guard itself)" >&2
  exit 1
}

mkdir -p "$CLAUDE_DIR/rules" "$CLAUDE_DIR/refs"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

echo "→ downloading CLAUDE.md"
fetch "$BASE/global-instructions.md" "$tmp"
if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && ! cmp -s "$tmp" "$CLAUDE_DIR/CLAUDE.md"; then
  backup="$CLAUDE_DIR/CLAUDE.md.backup-$(date +%Y%m%d%H%M%S)"
  echo "   keeping your previous CLAUDE.md as ${backup##*/}"
  mv "$CLAUDE_DIR/CLAUDE.md" "$backup"
fi
cp "$tmp" "$CLAUDE_DIR/CLAUDE.md"

for file in $RULES; do
  echo "→ downloading rules/$file"
  fetch "$BASE/rules/$file" "$CLAUDE_DIR/rules/$file"
done

for file in $REFS; do
  echo "→ downloading refs/$file"
  fetch "$BASE/plugin/refs/$file" "$CLAUDE_DIR/refs/$file"
done

for file in $LEGACY_HOOK_FILES; do
  [ -e "$CLAUDE_DIR/hooks/$file" ] || continue
  echo "→ removing superseded hooks/$file"
  rm -f "$CLAUDE_DIR/hooks/$file"
done
if [ -d "$CLAUDE_DIR/hooks/guards" ]; then
  echo "→ removing superseded hooks/guards/"
  rm -rf "$CLAUDE_DIR/hooks/guards"
fi

echo "→ merging marketplace, plugins and ask rules into settings.json"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
# `make` is the one wrapper with nothing to classify: a target name says nothing
# about what it runs. The hook expands the recipe when it can read the
# Makefile; these name-based rules are the backstop for when it cannot. Keep in
# sync with claude/settings.json by hand — bootstrap cannot read the repo.
jq --arg repo "$MARKETPLACE_REPO" '
  .extraKnownMarketplaces //= {}
  | .extraKnownMarketplaces["claude-plugins-official"] //= {source: {source: "github", repo: "anthropics/claude-plugins-official"}}
  | .extraKnownMarketplaces.ezintz //= {source: {source: "github", repo: $repo}}
  | .enabledPlugins //= {}
  | .enabledPlugins["dotfiles@ezintz"] //= true
  | .enabledPlugins["skill-creator@claude-plugins-official"] //= true
  | .permissions.ask = ((.permissions.ask // []) as $have
      | $have + (["Bash(make deploy*)", "Bash(make apply*)", "Bash(make destroy*)",
                  "Bash(make release*)", "Bash(make publish*)"] - $have))
  | if .hooks.PreToolUse then
      .hooks.PreToolUse |= (map(.hooks |= map(select((.command // "")
          | test("^~/\\.claude/hooks/(env-guard|kubectl-env-guard|terraform-env-guard|openstack-env-guard|argocd-env-guard)\\.sh$") | not)))
        | map(select((.hooks | length) > 0)))
      | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end
    else . end
  | if .hooks == {} then del(.hooks) else . end
' "$SETTINGS" > "$tmp"
cp "$tmp" "$SETTINGS"

# settings.json alone makes Claude Code offer the plugin on its next start;
# with the CLI on PATH it is installed right away instead.
if command -v claude >/dev/null 2>&1; then
  echo "→ installing the dotfiles plugin"
  claude plugin marketplace add "$MARKETPLACE_REPO" >/dev/null 2>&1 || true
  claude plugin install dotfiles@ezintz
else
  echo "→ claude is not on PATH; install the plugin later with: claude plugin install dotfiles@ezintz"
fi

echo "✓ done — restart Claude Code for the plugin and hook to take effect."
