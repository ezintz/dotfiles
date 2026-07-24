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
#   ~/.claude/hooks/kubectl-env-guard.sh      kubectl/helm guard (executable)
#   ~/.claude/hooks/terraform-env-guard.sh    terraform/tofu guard (executable)
#   ~/.claude/settings.json                   PreToolUse hooks registered/merged
#
# Safe to re-run: existing settings are preserved and hooks are not duplicated.
# Override the source with CLAUDE_BOOTSTRAP_BASE (e.g. to pin a branch/fork).

set -eu

BASE="${CLAUDE_BOOTSTRAP_BASE:-https://raw.githubusercontent.com/ezintz/dotfiles/main/claude}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

# Hooks to install: "<filename>|<statusMessage>"
HOOKS="kubectl-env-guard.sh|Checking kubectl target environment...
terraform-env-guard.sh|Checking terraform/tofu target..."

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

mkdir -p "$CLAUDE_DIR/hooks"

echo "→ downloading CLAUDE.md"
fetch "$BASE/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

echo "$HOOKS" | while IFS='|' read -r file msg; do
  [ -n "$file" ] || continue
  echo "→ downloading $file"
  fetch "$BASE/hooks/$file" "$CLAUDE_DIR/hooks/$file"
  chmod +x "$CLAUDE_DIR/hooks/$file"
done

echo "→ registering PreToolUse hooks in settings.json"
python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
entries = [
    {
        "type": "command",
        "command": "~/.claude/hooks/kubectl-env-guard.sh",
        "timeout": 15,
        "statusMessage": "Checking kubectl target environment...",
    },
    {
        "type": "command",
        "command": "~/.claude/hooks/terraform-env-guard.sh",
        "timeout": 15,
        "statusMessage": "Checking terraform/tofu target...",
    },
]

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

cmds = block.setdefault("hooks", [])
have = {h.get("command") for h in cmds}
for entry in entries:
    if entry["command"] not in have:
        cmds.append(entry)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("   settings.json updated")
PY

echo "✓ done — reload Claude Code for the hooks to take effect."
