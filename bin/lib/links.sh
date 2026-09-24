# Symlinking the tracked config into $HOME. Sourced by bin/dotfiles.

# link <source relative to the repo> <target relative to $HOME>
#
# The target ends up as a symlink to the source, whatever was there before:
# a link to somewhere else is repointed, and a real file *or directory* is
# moved aside with a timestamp, never deleted. The target is always replaced
# rather than written into — a bare `ln -s` onto an existing directory would
# create the link *inside* it instead.
link() {
  _src="${DOTFILES_DIRECTORY}/$1"
  _dest="${HOME}/$2"

  if [ -L "$_dest" ]; then
    [ "$(readlink "$_dest")" = "$_src" ] && return 0
    print_notice "Repointing ~/$2 (was -> $(readlink "$_dest"))"
    run rm -f "$_dest"
  elif [ -e "$_dest" ]; then
    _backup="${_dest}.backup-$(date +%Y%m%d%H%M%S)"
    print_notice "Moving existing ~/$2 aside to ${_backup#"$HOME"/}"
    run mv "$_dest" "$_backup"
  fi

  [ -d "$(dirname "$_dest")" ] || run mkdir -p "$(dirname "$_dest")"
  run ln -s "$_src" "$_dest"
}

# link_each <source dir relative to the repo> <target dir relative to $HOME> <glob>
#
# One link per entry, never the directory as a whole: ~/.claude/rules and
# ~/.claude/themes can hold entries this repo does not own.
link_each() {
  for _entry in "${DOTFILES_DIRECTORY}/$1"/$3; do
    [ -e "$_entry" ] || continue
    link "$1/${_entry##*/}" "$2/${_entry##*/}"
  done
}

mirror_files() {
  [ -d "${HOME}/.ssh/control" ] || run mkdir -p "${HOME}/.ssh/control"
  [ -n "${DOTFILES_DRY_RUN:-}" ] || chmod 700 "${HOME}/.ssh"

  link "curlrc" ".curlrc"
  link "wgetrc" ".wgetrc"

  link "ssh/config" ".ssh/config"

  link "git/gitignore" ".gitignore"
  link "git/gitattributes" ".gitattributes"
  link "git/gitconfig" ".gitconfig"

  link "prezto/runcoms/zlogin" ".zlogin"
  link "prezto/runcoms/zlogout" ".zlogout"
  link "prezto/runcoms/zprofile" ".zprofile"
  link "prezto/runcoms/zpreztorc" ".zpreztorc"
  link "prezto/runcoms/zshenv" ".zshenv"
  link_zshrc

  link "tmux/tmux.conf" ".tmux.conf"
  link "tmux/plugins" ".tmux/plugins"

  ## cmux embeds libghostty and exposes no cursor/font settings of its own, so
  ## this file is cmux's terminal config as much as Ghostty's.
  link "ghostty/config" ".config/ghostty/config"
  link "ghostty/passthrough.glsl" ".config/ghostty/passthrough.glsl"
  if is_macos; then
    link "cmux/cmux.json" ".config/cmux/cmux.json"
  fi
  ## login(1) prints "Last login: …" before the shell starts. In cmux that line
  ## is drawn and then replaced by the tmux screen tmux/cmux.zsh attaches, so
  ## every new tab visibly loads twice. The file's existence alone silences it.
  [ -e "${HOME}/.hushlogin" ] || run touch "${HOME}/.hushlogin"
}

## ~/.zshrc is the one file left alone when it already exists, so machine-local
## shell setup can live there. But the tracked zshrc is also what loads prezto
## and the cmux/tmux integration, so skipping it silently left a shell with
## neither and no hint why.
link_zshrc() {
  if [ ! -e "${HOME}/.zshrc" ] && [ ! -L "${HOME}/.zshrc" ]; then
    link "prezto/runcoms/zshrc" ".zshrc"
  elif [ "$(readlink "${HOME}/.zshrc" 2>/dev/null)" != "${DOTFILES_DIRECTORY}/prezto/runcoms/zshrc" ] &&
       ! grep -q 'prezto/runcoms/zshrc' "${HOME}/.zshrc" 2>/dev/null; then
    # shellcheck disable=SC2088 # shown to the user, not expanded
    print_warning "~/.zshrc exists and was left alone, so prezto is not loaded. Add this line to it:"
    printf '    source "%s/prezto/runcoms/zshrc"\n' "$DOTFILES_DIRECTORY"
  fi
}

# One-time move to the XDG layout. The overlay used to be ~/.dotfiles-private,
# and its rc fragments were symlinked into $HOME as ~/.<name>.local (some
# machines have them as real files there instead). Now everything lives in
# $DOTFILES_LOCAL_DIRECTORY under its plain name and the tracked config reads
# it from there, so nothing is linked into $HOME any more. Never overwrites:
# when both an old and a new copy exist, the old one is left and reported.
migrate_overlay() {
  _old="${HOME}/.dotfiles-private"
  if [ -d "$_old" ] && [ ! -L "$_old" ]; then
    if [ -e "$DOTFILES_LOCAL_DIRECTORY" ]; then
      print_warning "Both ${_old} and ${DOTFILES_LOCAL_DIRECTORY} exist; merge them by hand."
    else
      print_notice "Moving the private overlay ${_old} to ${DOTFILES_LOCAL_DIRECTORY}"
      run mkdir -p "$(dirname "$DOTFILES_LOCAL_DIRECTORY")"
      run mv "$_old" "$DOTFILES_LOCAL_DIRECTORY"
    fi
  fi

  for _entry in \
    ".gitconfig.local:gitconfig.local:gitconfig" \
    ".zpreztorc.local:zpreztorc.local:zpreztorc" \
    ".tmux.conf.local:tmux.conf.local:tmux.conf" \
    ".zprofile.local:zprofile.local:zprofile" \
    ".zshrc.local:zshrc.local:zshrc" \
    ".gitauthor::gitauthor"
  do
    _home="${HOME}/${_entry%%:*}"
    _rest="${_entry#*:}"
    _oldname="${_rest%%:*}"
    _new="${DOTFILES_LOCAL_DIRECTORY}/${_rest#*:}"

    # Old name inside the overlay itself.
    if [ -n "$_oldname" ] && [ -f "${DOTFILES_LOCAL_DIRECTORY}/${_oldname}" ]; then
      if [ -e "$_new" ]; then
        print_warning "Both ${DOTFILES_LOCAL_DIRECTORY}/${_oldname} and ${_new} exist; keeping ${_new}."
      else
        run mv "${DOTFILES_LOCAL_DIRECTORY}/${_oldname}" "$_new"
      fi
    fi

    # The old copy or link in $HOME.
    if [ -L "$_home" ]; then
      run rm -f "$_home"
    elif [ -f "$_home" ]; then
      if [ -e "$_new" ]; then
        print_warning "Both ${_home} and ${_new} exist; ${_home} is no longer read, merge it by hand."
      else
        print_notice "Moving ${_home} to ${_new}"
        [ -d "$DOTFILES_LOCAL_DIRECTORY" ] || run mkdir -p "$DOTFILES_LOCAL_DIRECTORY"
        run mv "$_home" "$_new"
      fi
    fi
  done

  migrate_overlay_secrets
  migrate_ssh_hosts
}

# Keys never go into the overlay's repository: they live in the untracked
# secrets.env (sourced by the prezto zprofile right after the overlay's
# zprofile). Moves `export <NAME>_API_KEY|_TOKEN|_SECRET|_PASSWORD|_PAT=…` lines
# out of the overlay's rc files, and the same kind of keys out of claude/mcp.json — the live
# ~/.claude.json keeps its copy, since merge_json never deletes a key.
SECRET_NAME_RE='[A-Z0-9_]*(_API_KEY|_TOKEN|_SECRET|_PASSWORD|_PAT)'
migrate_overlay_secrets() {
  _sec="${DOTFILES_LOCAL_DIRECTORY}/secrets.env"
  for _rc in zprofile zshrc zpreztorc; do
    _zp="${DOTFILES_LOCAL_DIRECTORY}/${_rc}"
    if [ ! -f "$_zp" ] || ! grep -qE "^[[:space:]]*export[[:space:]]+${SECRET_NAME_RE}=" "$_zp"; then
      continue
    fi
    print_notice "Moving keys from ${_zp} to ${_sec} (never backed up)"
    [ -n "${DOTFILES_DRY_RUN:-}" ] && continue
    ( umask 077
      grep -E "^[[:space:]]*export[[:space:]]+${SECRET_NAME_RE}=" "$_zp" >> "$_sec"
      grep -vE "^[[:space:]]*export[[:space:]]+${SECRET_NAME_RE}=" "$_zp" > "${_zp}.tmp" )
    mv "${_zp}.tmp" "$_zp"
    chmod 600 "$_sec"
  done

  _mcp="${DOTFILES_LOCAL_DIRECTORY}/claude/mcp.json"
  if [ -f "$_mcp" ] && has jq &&
     jq -e --arg re "^${SECRET_NAME_RE}\$" '[.mcpServers[]?.env // {} | keys[] | select(test($re))] | length > 0' "$_mcp" >/dev/null 2>&1; then
    print_notice "Moving keys from ${_mcp} to ${_sec} (the live ~/.claude.json keeps them)"
    if [ -z "${DOTFILES_DRY_RUN:-}" ]; then
      ( umask 077
        jq -r --arg re "^${SECRET_NAME_RE}\$" '.mcpServers[]?.env // {} | to_entries[] | select(.key | test($re)) | "export \(.key)=\(.value | @sh)"' "$_mcp" >> "$_sec"
        jq --arg re "^${SECRET_NAME_RE}\$" '(.mcpServers[]?.env // empty) |= with_entries(select(.key | test($re) | not))' "$_mcp" > "${_mcp}.tmp" )
      mv "${_mcp}.tmp" "$_mcp"
      chmod 600 "$_sec"
    fi
  fi
}

# SSH host files used to sit untracked in this repo's ssh/config.d, linked to
# ~/.ssh/config.d. They are personal, so they belong in the overlay, where
# ssh/config includes them from and where they are backed up.
migrate_ssh_hosts() {
  _old="${DOTFILES_DIRECTORY}/ssh/config.d"
  if [ -d "$_old" ]; then
    for _f in "$_old"/*; do
      [ -f "$_f" ] || continue
      git -C "$DOTFILES_DIRECTORY" ls-files --error-unmatch "$_f" >/dev/null 2>&1 && continue
      [ -d "${DOTFILES_LOCAL_DIRECTORY}/ssh" ] || run mkdir -p "${DOTFILES_LOCAL_DIRECTORY}/ssh"
      if [ -e "${DOTFILES_LOCAL_DIRECTORY}/ssh/${_f##*/}" ]; then
        print_warning "Both ${_f} and the overlay's ssh/${_f##*/} exist; keeping the overlay's."
        continue
      fi
      print_notice "Moving SSH host file ${_f##*/} into the overlay"
      run mv "$_f" "${DOTFILES_LOCAL_DIRECTORY}/ssh/"
    done
    [ -n "$(ls -A "$_old" 2>/dev/null)" ] || run rmdir "$_old"
  fi
  if [ -L "${HOME}/.ssh/config.d" ]; then
    run rm -f "${HOME}/.ssh/config.d"
  fi
}
