# The global Claude Code setup (~/.claude). Sourced by bin/dotfiles.
#
# claude/plugin is a standard Claude Code plugin (skills, agents, the env-guard
# hook). Here it is linked to ~/.claude/skills/dotfiles, where Claude Code loads
# a plugin in place as `dotfiles@skills-dir` — so edits in this checkout are
# live. Installing it from the `ezintz` marketplace instead copies it into
# ~/.claude/plugins/cache, which is right for someone without this checkout
# and wrong here. What a plugin cannot carry (global instructions, rules,
# settings, the statusline, themes) is still linked or merged individually.

# Old layouts linked every skill, agent, ref and hook script individually, and
# registered the hook in settings.json. Left behind, they load every skill a
# second time next to the plugin's copy and run the guard twice.
prune_claude_links() {
  for _dir in skills agents refs hooks rules themes; do
    for _l in "${HOME}/.claude/${_dir}"/* "${HOME}/.claude/${_dir}"/.[!.]*; do
      [ -L "$_l" ] || continue
      _t=$(readlink "$_l")
      case "$_t" in
        "${DOTFILES_DIRECTORY}/claude/"*|"${DOTFILES_LOCAL_DIRECTORY}/claude/"*) ;;
        *) continue ;;
      esac
      # Links this run creates again anyway are kept, so a re-run is quiet.
      case "$_t" in
        "${DOTFILES_DIRECTORY}/claude/plugin") [ "${_l##*/}" = dotfiles ] && [ -e "$_t" ] && continue ;;
        "${DOTFILES_DIRECTORY}/claude/plugin/refs/knowledge-placement.md"|\
        "${DOTFILES_DIRECTORY}/claude/rules/"*|\
        "${DOTFILES_DIRECTORY}/claude/themes/"*|\
        "${DOTFILES_LOCAL_DIRECTORY}/claude/skills/"*) [ -e "$_t" ] && continue ;;
      esac
      print_notice "Removing superseded link ~/.claude/${_dir}/${_l##*/}"
      run rm -f "$_l"
    done
  done
}

## Private skills stay out of the public plugin, so they are linked one by one.
## A real directory of the same name is a machine-local skill and wins.
mirror_private_skills() {
  _src_dir="${DOTFILES_LOCAL_DIRECTORY}/claude/skills"
  [ -d "$_src_dir" ] || return 0
  for _skill in "$_src_dir"/*; do
    [ -d "$_skill" ] || continue
    _name="${_skill##*/}"
    _dest="${HOME}/.claude/skills/${_name}"
    if [ -d "$_dest" ] && [ ! -L "$_dest" ]; then
      print_warning "Skill '${_name}' exists as a local directory; not linking ${_skill}"
      continue
    fi
    [ "$(readlink "$_dest" 2>/dev/null)" = "$_skill" ] && continue
    run ln -sfn "$_skill" "$_dest"
  done
}

# merge_json <source file> <target relative to $HOME>
#
# Deep-merges the source into the target: objects merge key by key with the
# source winning on conflicts, and arrays are *unioned*, not replaced. jq's
# own `*` replaces arrays, which wiped every hook and permission rule the user
# had added to ~/.claude/settings.json on each run. The price of the union is
# that deleting an array entry here does not delete it there — that takes an
# explicit migration, like prune_legacy_hook below.
# shellcheck disable=SC2016 # a jq program: $vars are jq's, not the shell's
MERGE_JQ='
def union($a; $b):
  if ($a|type) == "object" and ($b|type) == "object" then
    reduce (($a|keys_unsorted) + (($b|keys_unsorted) - ($a|keys_unsorted)))[] as $k
      ({}; .[$k] = if ($a|has($k)) and ($b|has($k)) then union($a[$k]; $b[$k])
                   elif ($b|has($k)) then $b[$k] else $a[$k] end)
  elif ($a|type) == "array" and ($b|type) == "array" then $a + ($b - $a)
  else $b end;
union(.[0]; .[1])'

merge_json() {
  _src="$1"
  _dest="${HOME}/$2"
  [ -f "$_src" ] || return 0
  if ! has jq; then
    print_warning "jq not found; skipping the merge of ${_src#"$HOME"/} into ~/$2"
    return 0
  fi
  if [ -n "${DOTFILES_DRY_RUN:-}" ]; then
    printf '  would merge: %s -> ~/%s\n' "$_src" "$2"
    return 0
  fi
  mkdir -p "$(dirname "$_dest")"
  if [ ! -e "$_dest" ]; then
    cp "$_src" "$_dest"
    return 0
  fi
  json_rewrite "$_dest" "$MERGE_JQ" "$_dest" "$_src"
}

# json_rewrite <file> <jq program> <jq input files...>
# Writes through a temp file so a failed jq leaves the original untouched, and
# replaces a symlink from an older setup with a real file.
json_rewrite() {
  _file="$1"; _prog="$2"; shift 2
  _tmp="${_file}.dotfiles-tmp"
  if jq -s "$_prog" "$@" > "$_tmp" 2>/dev/null; then
    rm -f "$_file"
    mv "$_tmp" "$_file"
  else
    print_warning "Could not update ~/${_file#"$HOME"/}; left untouched"
    rm -f "$_tmp"
  fi
}

# The guard used to be registered in settings.json. It now comes from the
# plugin's hooks.json, and the array union never removes the old entry.
prune_legacy_hook() {
  _settings="${HOME}/.claude/settings.json"
  [ -f "$_settings" ] && has jq || return 0
  jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty
          | select(test("^~/\\.claude/hooks/(env-guard|kubectl-env-guard|terraform-env-guard|openstack-env-guard|argocd-env-guard)\\.sh$"))]
         | length > 0' "$_settings" >/dev/null 2>&1 || return 0
  print_notice "Removing the old env-guard hook entry from ~/.claude/settings.json"
  [ -n "${DOTFILES_DRY_RUN:-}" ] && return 0
  json_rewrite "$_settings" '.[0]
    | .hooks.PreToolUse |= (map(.hooks |= map(select((.command // "")
        | test("^~/\\.claude/hooks/(env-guard|kubectl-env-guard|terraform-env-guard|openstack-env-guard|argocd-env-guard)\\.sh$") | not)))
      | map(select((.hooks | length) > 0)))
    | if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end' "$_settings"
}

# The retired claude/bootstrap.sh *copied* the guard into ~/.claude/hooks
# instead of linking it, so prune_claude_links never sees those copies. Left
# behind, a stale guard keeps running from there and never updates. Matched by
# content, not just name, so an unrelated file that happens to share a name
# survives.
prune_legacy_hook_copies() {
  _hooks="${HOME}/.claude/hooks"
  for _f in env-guard.sh guard-lib.sh kubectl-env-guard.sh terraform-env-guard.sh openstack-env-guard.sh argocd-env-guard.sh; do
    [ -f "${_hooks}/${_f}" ] && [ ! -L "${_hooks}/${_f}" ] || continue
    grep -q 'guard' "${_hooks}/${_f}" 2>/dev/null || continue
    print_notice "Removing copied legacy hook ~/.claude/hooks/${_f}"
    run rm -f "${_hooks}/${_f}"
  done
  if [ -d "${_hooks}/guards" ] && [ ! -L "${_hooks}/guards" ] && [ -f "${_hooks}/guards/kubectl.guard" ]; then
    print_notice "Removing copied legacy hook profiles ~/.claude/hooks/guards/"
    run rm -rf "${_hooks}/guards"
  fi
}

# Every plugin set to true in `enabledPlugins` — tracked settings.json plus the
# private overlay's — is installed. That key is already the list, so there is
# no second one to drift from it. A fresh machine does not know any
# marketplace yet and `plugin install` then fails with "not found", so every
# marketplace in `extraKnownMarketplaces` is added first. Both commands are
# no-ops when already done. Additive, like the Brewfile: a plugin installed by
# hand and not listed stays.
install_claude_plugins() {
  if ! has claude; then
    print_notice "claude is not installed yet; skipping Claude Code plugins"
    return 0
  fi
  has jq || return 0
  _settings=$(for _f in "${DOTFILES_DIRECTORY}/claude/settings.json" "${DOTFILES_LOCAL_DIRECTORY}/claude/settings.json"; do
    [ -f "$_f" ] && printf '%s\n' "$_f"
  done)
  [ -n "$_settings" ] || return 0

  print_header "Installing Claude Code plugins ..."
  # One marketplace per line: <name> <source for `marketplace add`>.
  # shellcheck disable=SC2086 # one file per line, no spaces in these paths
  jq -rs '[.[].extraKnownMarketplaces // {} | to_entries[]] | unique_by(.key)[]
          | "\(.key) \(.value.source | .repo // .url // .path // empty)"' $_settings |
  while read -r _name _source; do
    [ -n "$_source" ] || continue
    run_quiet claude plugin marketplace add "$_source" ||
      print_warning "Could not add Claude Code marketplace ${_name} (${_source})"
  done
  # shellcheck disable=SC2086
  for _plugin in $(jq -rs '[.[].enabledPlugins // {} | to_entries[] | select(.value == true) | .key] | unique[]' $_settings); do
    run_quiet claude plugin install "$_plugin" ||
      print_warning "Could not install Claude Code plugin ${_plugin}"
  done
}

setup_claude() {
  prune_claude_links
  prune_legacy_hook
  prune_legacy_hook_copies

  ## Named differently from the symlink target so Claude Code's in-repo
  ## CLAUDE.md auto-discovery doesn't also load it a second time as a
  ## project file when working inside this repo.
  link "claude/global-instructions.md" ".claude/CLAUDE.md"
  link "claude/statusline-command.sh" ".claude/statusline-command.sh"
  link "claude/plugin" ".claude/skills/dotfiles"
  link_each "claude/rules" ".claude/rules" "*.md"
  ## The rule's pointer names ~/.claude/refs; the file itself lives in the
  ## plugin because the plugin's skills link it too.
  link "claude/plugin/refs/knowledge-placement.md" ".claude/refs/knowledge-placement.md"
  ## Claude Code's `/theme` editor rewrites a theme by renaming a temp file over
  ## it, which replaces the symlink with a regular file -- so a theme tweaked in
  ## the UI detaches from this repo until the next run re-links it.
  link_each "claude/themes" ".claude/themes" "*.json"
  mirror_private_skills

  merge_json "${DOTFILES_DIRECTORY}/claude/settings.json" ".claude/settings.json"
  ## Personal choices that should not be forced on anyone forking this repo
  ## (auto permission mode, skipped safety prompts) live in the private overlay.
  merge_json "${DOTFILES_LOCAL_DIRECTORY}/claude/settings.json" ".claude/settings.json"
  ## User-scope MCP servers live in ~/.claude.json (top-level mcpServers).
  ## Keys are never written here: servers read them from the environment,
  ## exported by the overlay's secrets.env (see migrate_overlay_secrets).
  merge_json "${DOTFILES_DIRECTORY}/claude/mcp.json" ".claude.json"
  ## Servers with local paths or keys (CodeGraphContext) stay private.
  merge_json "${DOTFILES_LOCAL_DIRECTORY}/claude/mcp.json" ".claude.json"
  install_claude_plugins
}
