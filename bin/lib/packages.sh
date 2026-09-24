# Package installation. Sourced by bin/dotfiles.

# Homebrew is not on PATH in a shell that predates its install, nor in a
# non-login `sh`; brew's own shellenv fixes both.
load_homebrew() {
  has brew && return 0
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_brew" ]; then
      eval "$("$_brew" shellenv)"
      return 0
    fi
  done
  return 1
}

install_brew_packages() {
  load_homebrew || abort "Homebrew is not installed. Run install.sh, which installs it, or see https://brew.sh."

  print_header "Installing Homebrew packages ..."
  ## --adopt takes over an app that is already in /Applications (installed by
  ## hand or from a DMG) instead of failing the whole bundle on it.
  brew_bundle "${DOTFILES_DIRECTORY}/Brewfile"
  run brew cleanup
}

## --verbose passes through each install's own output (download progress,
## a .pkg's password prompt); without it a long download looks like a hang.
brew_bundle() {
  [ -f "$1" ] || return 0
  run env HOMEBREW_CASK_OPTS="--adopt ${HOMEBREW_CASK_OPTS:-}" \
    brew bundle install --verbose --file "$1" ||
    print_warning "brew bundle reported failures for $1"
}

# The overlay's own Brewfile runs separately, after setup_overlay: on a new
# machine the overlay only exists once it has been restored.
install_overlay_packages() {
  is_macos && load_homebrew || return 0
  if [ -f "${DOTFILES_LOCAL_DIRECTORY}/packages.zsh" ]; then
    print_warning "${DOTFILES_LOCAL_DIRECTORY}/packages.zsh is no longer read; move its packages to ${DOTFILES_LOCAL_DIRECTORY}/Brewfile"
  fi
  brew_bundle "${DOTFILES_LOCAL_DIRECTORY}/Brewfile"
}

# The minimum for the shell, git and the Claude Code guard on a server:
# packages/linux.txt, installed with whichever package manager is present.
# On apt and apk they hang off one virtual package, `dotfiles`, so dropping a
# name from the list lets the package manager remove it again instead of it
# staying installed forever, and removing `dotfiles` undoes the whole list.
# $_sudo and $_list are unquoted on purpose: an empty $_sudo must vanish and
# $_list must split into one argument per package.
# shellcheck disable=SC2086
install_linux_packages() {
  _list=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${DOTFILES_DIRECTORY}/packages/linux.txt" | tr '\n' ' ')
  if [ "$(id -u)" = 0 ]; then
    _sudo=
  elif has sudo; then
    _sudo=sudo
  else
    print_warning "Not root and no sudo; install these yourself: ${_list}"
    return 0
  fi

  print_header "Installing packages: ${_list}"
  if has apt-get; then
    install_apt_metapackage
  elif has dnf; then
    run $_sudo dnf install -y $_list
  elif has apk; then
    # apk is declarative: re-adding the virtual package with a shorter list
    # removes what was dropped, unless something else still needs it.
    run $_sudo apk add --no-cache --virtual dotfiles $_list
  elif has pacman; then
    # -Syu, not -Sy: Arch does not support partial upgrades, and -Sy <pkg> can
    # install a package built against libraries newer than the system's.
    run $_sudo pacman -Syu --needed --noconfirm $_list
  else
    print_warning "No supported package manager (apt, dnf, apk, pacman); install these yourself: ${_list}"
    return 0
  fi || print_warning "Installing packages failed; install these yourself: ${_list}"
}

# apt has no --virtual, so build the metapackage: a .deb that is nothing but
# a control file whose Depends is the list. dpkg-deb comes with dpkg, so no
# tool or repository is needed. apt skips a version it already has, so the
# version moves only when the list does, and an unchanged list is left alone.
# Afterwards `apt-get autoremove` takes out a package dropped from the list.
# shellcheck disable=SC2086
install_apt_metapackage() {
  _depends=$(printf '%s\n' $_list | paste -sd, - | sed 's/,/, /g')
  if [ "$(dpkg-query -W -f '${Depends}' dotfiles 2>/dev/null)" = "$_depends" ]; then
    return 0
  fi
  _version=$(dpkg-query -W -f '${Version}' dotfiles 2>/dev/null) || _version=0
  _version=$((${_version:-0} + 1))
  _build=$(mktemp -d) || return 1
  ## World-readable, or apt's sandbox user cannot open the .deb and says so.
  chmod 755 "$_build"
  mkdir "$_build/dotfiles" "$_build/dotfiles/DEBIAN"
  cat >"$_build/dotfiles/DEBIAN/control" <<EOC
Package: dotfiles
Version: ${_version}
Architecture: all
Maintainer: dotfiles <root@localhost>
Depends: ${_depends}
Description: Packages the dotfiles need on this server
 Built by bin/dotfiles from packages/linux.txt.
EOC
  dpkg-deb --build --root-owner-group "$_build/dotfiles" "$_build/dotfiles.deb" >/dev/null &&
    run $_sudo apt-get update -q &&
    run $_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$_build/dotfiles.deb"
  _status=$?
  rm -rf "$_build"
  return $_status
}

install_packages() {
  if is_macos; then
    install_brew_packages
  elif is_linux; then
    install_linux_packages
  fi
}
