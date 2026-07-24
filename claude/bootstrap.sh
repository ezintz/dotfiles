#!/usr/bin/env sh
#
# Bootstrap the Claude Code kubectl env-guard on any machine WITHOUT cloning
# the dotfiles repo. Installs the global instructions + the PreToolUse guard
# hook, and registers the hook in settings.json (non-destructive, idempotent).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/claude/bootstrap.sh | sh
#
# Installs:
#   ~/.claude/CLAUDE.md                    global instructions
#   ~/.claude/hooks/kubectl-env-guard.sh   PreToolUse guard (executable)
#   ~/.claude/settings.json                PreToolUse hook registered/merged
#
# Safe to re-run: existing settings are preserved and the hook is not duplicated.
# Override the source with CLAUDE_BOOTSTRAP_BASE (e.g. to pin a branch/fork).

set -eu

BASE="${CLAUDE_BOOTSTRAP_BASE:-https://raw.githubusercontent.com/ezintz/dotfiles/main/claude}"
CLAUDE_DIR="$HOME/.claude"
HOOK_PATH="$CLAUDE_DIR/hooks/kubectl-env-guard.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

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

echo "→ downloading kubectl-env-guard.sh"
fetch "$BASE/hooks/kubectl-env-guard.sh" "$HOOK_PATH"
chmod +x "$HOOK_PATH"

echo "→ registering PreToolUse hook in settings.json"
python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
entry = {
    "type": "command",
    "command": "~/.claude/hooks/kubectl-env-guard.sh",
    "timeout": 15,
    "statusMessage": "Checking kubectl target environment...",
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

cmds = block.setdefault("hooks", [])
if not any(h.get("command") == entry["command"] for h in cmds):
    cmds.append(entry)

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("   settings.json updated")
PY

echo "✓ done — reload Claude Code for the hook to take effect."
