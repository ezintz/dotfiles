#!/usr/bin/env sh
#
# Bootstrap the Claude Code env-guards on any machine WITHOUT cloning the
# dotfiles repo. Installs the global instructions + the PreToolUse guard hooks,
# and registers them in settings.json (non-destructive, idempotent).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/claude/bootstrap.sh | sh
#
# Installs:
#   ~/.claude/CLAUDE.md                       global instructions
#   ~/.claude/hooks/env-guard.sh              the one PreToolUse hook (executable)
#   ~/.claude/hooks/guard-lib.sh              shared command-parsing helpers
#   ~/.claude/hooks/guards/*.guard            one profile per guarded tool
#   ~/.claude/settings.json                   PreToolUse hook + plugins merged
#
# Safe to re-run: existing settings are preserved and hooks are not duplicated.
# Override the source with CLAUDE_BOOTSTRAP_BASE (e.g. to pin a branch/fork).

set -eu

BASE="${CLAUDE_BOOTSTRAP_BASE:-https://raw.githubusercontent.com/ezintz/dotfiles/main/claude}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# The only registered hook.
HOOK="env-guard.sh"
HOOK_STATUS="Checking target environment..."

# Sourced by the hook, never registered. A raw.githubusercontent fetch cannot
# glob a remote directory, so unlike bin/dotfiles this list is explicit —
# adding a guard means adding its filename here too.
SUPPORT="guard-lib.sh"
PROFILES="_kube-context.sh
_scm-origin.sh
kubectl.guard
helm.guard
terraform.guard
openstack.guard
argocd.guard
ansible.guard
helmfile.guard
terragrunt.guard
skaffold.guard
git.guard
gh.guard
glab.guard"

# Hooks from the pre-dispatcher one-hook-per-tool layout, removed from
# settings.json and from disk so nothing points at a script that is gone.
LEGACY_HOOKS="kubectl-env-guard.sh
terraform-env-guard.sh
openstack-env-guard.sh
argocd-env-guard.sh"

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

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to merge settings.json" >&2
  exit 1
}

mkdir -p "$CLAUDE_DIR/hooks/guards"

echo "→ downloading CLAUDE.md"
fetch "$BASE/global-instructions.md" "$CLAUDE_DIR/CLAUDE.md"

for file in $SUPPORT; do
  echo "→ downloading $file"
  fetch "$BASE/hooks/$file" "$CLAUDE_DIR/hooks/$file"
done

for file in $PROFILES; do
  echo "→ downloading guards/$file"
  fetch "$BASE/hooks/guards/$file" "$CLAUDE_DIR/hooks/guards/$file"
done

echo "→ downloading $HOOK"
fetch "$BASE/hooks/$HOOK" "$CLAUDE_DIR/hooks/$HOOK"
chmod +x "$CLAUDE_DIR/hooks/$HOOK"

for file in $LEGACY_HOOKS; do
  [ -e "$CLAUDE_DIR/hooks/$file" ] || continue
  echo "→ removing superseded $file"
  rm -f "$CLAUDE_DIR/hooks/$file"
done

echo "→ registering PreToolUse hook, wrapper ask rules and plugins in settings.json"
python3 - "$SETTINGS" "$HOOK" "$HOOK_STATUS" <<'PY'
import json, os, sys

path, hook, status = sys.argv[1], sys.argv[2], sys.argv[3]

# Marketplaces to know about, and plugins to force-enable from them. Claude Code
# auto-registers claude-plugins-official on first interactive launch, but naming
# it here removes the ordering dependency when bootstrap runs on a fresh machine.
marketplaces = {
    "claude-plugins-official": {
        "source": {"source": "github", "repo": "anthropics/claude-plugins-official"},
    },
}
plugins = [
    "skill-creator@claude-plugins-official",
]

# `make` is the one wrapper with nothing to classify: a target name says nothing
# about what it runs. The hook expands the recipe when it can read the Makefile,
# and these name-based rules are the backstop for when it cannot (an included
# fragment, a recipe built from variables). Every other wrapper has a real
# profile instead. Keep in sync with claude/settings.json by hand — bootstrap
# cannot read the repo.
ask_rules = [
    "Bash(make deploy*)",
    "Bash(make apply*)",
    "Bash(make destroy*)",
    "Bash(make release*)",
    "Bash(make publish*)",
]

entry = {
    "type": "command",
    "command": f"~/.claude/hooks/{hook}",
    "timeout": 15,
    "statusMessage": status,
}

# Entries from the one-hook-per-tool layout the dispatcher replaced. Left in
# place they would run scripts this bootstrap just deleted, and Claude Code
# treats a hook that fails to execute as a hard error on every Bash call.
legacy = {
    "~/.claude/hooks/kubectl-env-guard.sh",
    "~/.claude/hooks/terraform-env-guard.sh",
    "~/.claude/hooks/openstack-env-guard.sh",
    "~/.claude/hooks/argocd-env-guard.sh",
}

try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, ValueError):
    data = {}

pre = data.setdefault("hooks", {}).setdefault("PreToolUse", [])
block = next((b for b in pre if b.get("matcher") == "Bash"), None)
if block is None:
    block = {"matcher": "Bash", "hooks": []}
    pre.append(block)

cmds = [h for h in block.setdefault("hooks", []) if h.get("command") not in legacy]
if entry["command"] not in {h.get("command") for h in cmds}:
    cmds.append(entry)
block["hooks"] = cmds

# Additive: never drop a marketplace or plugin the user enabled by hand.
known = data.setdefault("extraKnownMarketplaces", {})
for name, spec in marketplaces.items():
    known.setdefault(name, spec)

enabled = data.setdefault("enabledPlugins", {})
for plugin in plugins:
    enabled.setdefault(plugin, True)

# Additive too: an ask list the user curated by hand is added to, never replaced.
ask = data.setdefault("permissions", {}).setdefault("ask", [])
for rule in ask_rules:
    if rule not in ask:
        ask.append(rule)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("   settings.json updated")
PY

echo "✓ done — reload Claude Code for the hooks to take effect."
