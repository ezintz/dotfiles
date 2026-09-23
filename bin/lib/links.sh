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
  link "ssh/config.d" ".ssh/config.d"

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
    print_warning "~/.zshrc exists and was left alone, so prezto is not loaded. Add this line to it:"
    printf '    source "%s/prezto/runcoms/zshrc"\n' "$DOTFILES_DIRECTORY"
  fi
}

mirror_local_files() {
  [ -d "${DOTFILES_LOCAL_DIRECTORY}" ] || return 0

  for _entry in \
    "gitconfig.local:.gitconfig.local" \
    "zpreztorc.local:.zpreztorc.local" \
    "tmux.conf.local:.tmux.conf.local" \
    "zprofile.local:.zprofile.local" \
    "zshrc.local:.zshrc.local"
  do
    _src="${DOTFILES_LOCAL_DIRECTORY}/${_entry%%:*}"
    _dest="${HOME}/${_entry##*:}"
    [ -f "$_src" ] || continue
    [ "$(readlink "$_dest" 2>/dev/null)" = "$_src" ] && continue
    run ln -sfn "$_src" "$_dest"
  done
}
