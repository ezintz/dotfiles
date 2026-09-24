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
    run $_sudo apt-get update -q &&
      run $_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $_list
  elif has dnf; then
    run $_sudo dnf install -y $_list
  elif has apk; then
    run $_sudo apk add --no-cache $_list
  elif has pacman; then
    # -Syu, not -Sy: Arch does not support partial upgrades, and -Sy <pkg> can
    # install a package built against libraries newer than the system's.
    run $_sudo pacman -Syu --needed --noconfirm $_list
  else
    print_warning "No supported package manager (apt, dnf, apk, pacman); install these yourself: ${_list}"
    return 0
  fi || print_warning "Installing packages failed; install these yourself: ${_list}"
}

install_packages() {
  if is_macos; then
    install_brew_packages
  elif is_linux; then
    install_linux_packages
  fi
}
