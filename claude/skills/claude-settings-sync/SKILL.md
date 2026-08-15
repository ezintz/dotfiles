---
name: claude-settings-sync
description: Audits the live ~/.claude/settings.json against this dotfiles repo's tracked claude/settings.json and classifies every local-only or mismatched key as sync-worthy (belongs in the tracked file, so `bin/dotfiles` applies it everywhere) or machine-local (must stay out of the public repo — API keys, absolute paths, hardware/display prefs, employer-specific values). Use this whenever the user asks whether a Claude Code setting should be synced to dotfiles, wants a diff between their local settings and the tracked ones, mentions reconciling/auditing settings.json, or just changed a Claude Code setting and wonders if it should be tracked. Always reason about each key explicitly instead of guessing — this repo is public on GitHub, so getting the classification wrong leaks machine-specific or sensitive data.
allowed-tools:
  - Bash(jq:*)
  - Read
  - Edit
---

# Settings sync audit

`~/.dotfiles/claude/settings.json` is deep-merged into `~/.claude/settings.json`
by `merge_json` in `bin/dotfiles` (tracked keys win on conflict; keys that exist
**only** in the live file are left alone). Over time the live file drifts ahead
of the tracked one — a setting gets changed interactively, or Claude Code adds
a new key nobody committed. This skill finds that drift and helps decide, key
by key, whether it belongs in the tracked file.

The two files:
- Tracked: `claude/settings.json` in the dotfiles repo root (find the repo root
  with `git rev-parse --show-toplevel` if not already in it — don't assume `~/.dotfiles`).
- Live: `~/.claude/settings.json`.

**Never edit the live file.** It's regenerated from the tracked file on every
`bin/dotfiles` run; hand-edits to it just get overwritten or silently ignored
depending on which key you touched. All changes go through the tracked file.

## Step 1: Diff the two files

```bash
jq -S . ~/.claude/settings.json > /tmp/live.json
jq -S . <repo-root>/claude/settings.json > /tmp/tracked.json
diff /tmp/tracked.json /tmp/live.json
```

Sort keys (`-S`) so the diff is stable and easy to read. Three kinds of
difference matter:

1. **Key only in live** — a candidate to add to tracked.
2. **Key in both, different value** — tracked will overwrite live's value on
   the next `bin/dotfiles` run. Worth surfacing even though it's not a
   "missing" key: the user may have changed it locally on purpose, not
   realizing it'll get stomped.
3. **Key only in tracked** — already handled correctly (it's live too, since
   tracked always gets merged in); nothing to do. Don't report these.

Ignore this diff's structure for nested objects like `attribution` or
`enabledPlugins` — treat a changed sub-key as a difference in that object, not
the whole object as one opaque blob, so the recommendation can be specific
("add the new plugin", not "resync the entire enabledPlugins block").

## Step 2: Classify each difference

For every key found in step 1, decide **sync-worthy** or **machine-local**.
The question to ask for each one: *if I ran `bin/dotfiles` on a brand new
machine, would I want this value applied there too?*

**Lean machine-local** (do not recommend syncing) when the key is:
- Explicitly called out as machine-local in this repo's CLAUDE.md — `model`
  and `permissions` are named examples; `bin/dotfiles`'s merge intentionally
  preserves whatever the destination already has for these.
- A credential, token, API key, or anything that authenticates as this user
  or this machine.
- An absolute path, hostname, or identifier specific to this machine or to
  the user's employer/environment (internal service names, project keys,
  usernames baked into paths).
- Tied to physical hardware or terminal capabilities — e.g. a `tui` display
  mode depends on the terminal emulator in use, not on user preference alone.
- Anything you're not confident about. This repo is public — when in doubt,
  default to machine-local and say why you're unsure, rather than guessing
  toward sync.

**Lean sync-worthy** when the key is a workflow/behavior preference that's
about *how Claude Code should act*, independent of which machine it's on —
things like attribution settings, plugin enablement, statusline command,
theme, effort level, permission-prompt skip toggles, marketplace
registrations. These are exactly the kind of thing the tracked file already
holds (see the existing keys in `claude/settings.json` for the pattern).

If a value looks sync-worthy in shape but contains something sensitive (a
token embedded in a command string, an internal hostname in a URL), don't
silently classify it machine-local and drop it — flag the conflict
explicitly: "this looks like a preference but the value itself isn't safe to
publish; consider `~/.dotfiles-private` instead" (see this repo's CLAUDE.md
for the private-overlay mechanism, which is not implemented for
`settings.json` today but is used for other config files).

## Step 3: Present findings

One row per differing key. Keep reasoning to a sentence — the point is to let
the user sanity-check the call, not to write an essay:

| Key | Live value | Tracked value | Recommendation | Why |
|-----|-----------|---------------|-----------------|-----|
| `agentPushNotifEnabled` | `true` | *(absent)* | Sync | Behavior toggle, not machine-specific |
| `model` | `"sonnet"` | *(absent)* | Keep local | CLAUDE.md names this a preserved machine-local key |

End with a plain-language summary: "N keys look sync-worthy, M should stay
local." Do not edit anything yet.

## Step 4: Apply, only after confirmation

Ask which of the sync-worthy keys to actually add (default to "all of them"
if the user just says yes). Then use `Edit` on `<repo-root>/claude/settings.json`
directly — add or update only the confirmed keys, preserving the existing
key order and formatting style of the file as much as possible. Do not touch
`~/.claude/settings.json`.

After editing, remind the user:
- The live file already has the value, so nothing needs to happen at runtime
  — the tracked file just now matches it.
- The change is uncommitted; offer to show `git diff` for
  `claude/settings.json` but don't commit unless asked, per this repo's
  normal git workflow.
