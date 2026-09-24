#!/bin/sh
#
# First install on a machine that has nothing yet:
#
#   curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/main/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --yes        # no questions (except restart)
#
# Gets the prerequisites bin/dotfiles cannot get for itself — on macOS the
# Command Line Tools (which provide git) and Homebrew — then puts the
# repository at ~/.dotfiles and hands every argument on to bin/dotfiles.
#
# A server may have no git at all. The repository then arrives as a GitHub
# tarball, bin/dotfiles installs git with the other Linux packages, and the
# tarball is turned into a real checkout (with its submodules) at the end.
#
# DOTFILES_REMOTE / DOTFILES_BRANCH install a fork. The location is fixed:
# prezto's runcoms and tmux.conf name ~/.dotfiles.

set -eu

DOTFILES_REMOTE="${DOTFILES_REMOTE:-https://github.com/ezintz/dotfiles.git}"
DOTFILES_BRANCH="${DOTFILES_BRANCH:-main}"
DOTFILES_DIRECTORY="${HOME}/.dotfiles"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

yes=
for opt in "$@"; do
  case "$opt" in -y|--yes) yes=1 ;; esac
done

fetch() { # fetch <url> <dest>
  if has curl; then curl -fsSL "$1" -o "$2"
  elif has wget; then wget -qO "$2" "$1"
  else die "need curl or wget"
  fi
}

if [ "$(uname -s)" = Darwin ]; then
  ## /usr/bin/git is only a stub until the Command Line Tools are installed, and
  ## the install is a GUI dialog: start it, then wait for it to finish.
  if ! xcode-select -p >/dev/null 2>&1; then
    say "→ Installing the Xcode Command Line Tools (confirm the dialog) ..."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 10; done
  fi

  if ! has brew && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
    say "→ Installing Homebrew ..."
    installer=$(mktemp)
    fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh "$installer"
    if [ -n "$yes" ]; then
      NONINTERACTIVE=1 /bin/bash "$installer" < /dev/null
    else
      /bin/bash "$installer" < /dev/tty
    fi
    rm -f "$installer"
  fi
fi

from_tarball=
if [ -d "${DOTFILES_DIRECTORY}/.git" ]; then
  say "→ ${DOTFILES_DIRECTORY} already exists; using it."
elif [ -e "$DOTFILES_DIRECTORY" ]; then
  die "${DOTFILES_DIRECTORY} exists but is not a git checkout; move it aside and re-run."
elif has git; then
  say "→ Cloning ${DOTFILES_REMOTE} ..."
  git clone --recursive --branch "$DOTFILES_BRANCH" "$DOTFILES_REMOTE" "$DOTFILES_DIRECTORY"
else
  case "$DOTFILES_REMOTE" in
    https://github.com/*) repo=${DOTFILES_REMOTE#https://github.com/}; repo=${repo%.git} ;;
    *) die "git is not installed and ${DOTFILES_REMOTE} is not a GitHub URL to download a tarball from" ;;
  esac
  say "→ git is not installed; downloading ${repo}@${DOTFILES_BRANCH} as a tarball ..."
  archive=$(mktemp)
  fetch "https://codeload.github.com/${repo}/tar.gz/refs/heads/${DOTFILES_BRANCH}" "$archive"
  mkdir -p "$DOTFILES_DIRECTORY"
  tar -xzf "$archive" -C "$DOTFILES_DIRECTORY" --strip-components=1
  rm -f "$archive"
  from_tarball=1
fi

sh "${DOTFILES_DIRECTORY}/bin/dotfiles" "$@"

if [ -n "$from_tarball" ]; then
  if has git; then
    say "→ Turning the tarball into a git checkout ..."
    git -C "$DOTFILES_DIRECTORY" init -q
    git -C "$DOTFILES_DIRECTORY" symbolic-ref HEAD "refs/heads/${DOTFILES_BRANCH}"
    git -C "$DOTFILES_DIRECTORY" remote add origin "$DOTFILES_REMOTE"
    git -C "$DOTFILES_DIRECTORY" fetch -q origin "$DOTFILES_BRANCH"
    git -C "$DOTFILES_DIRECTORY" reset -q "origin/${DOTFILES_BRANCH}"
    git -C "$DOTFILES_DIRECTORY" branch -q --set-upstream-to "origin/${DOTFILES_BRANCH}"
    git -C "$DOTFILES_DIRECTORY" submodule update --init --recursive
    # The submodules committed to from here come out detached; bin/dotfiles
    # (sync_own_submodule) would attach them, but it already ran on the tarball.
    for _sub in prezto claude/plugin; do
      _branch=$(git -C "$DOTFILES_DIRECTORY" config -f .gitmodules "submodule.${_sub}.branch" || echo main)
      if git -C "${DOTFILES_DIRECTORY}/${_sub}" merge-base --is-ancestor HEAD "origin/${_branch}" 2>/dev/null; then
        git -C "${DOTFILES_DIRECTORY}/${_sub}" checkout -q -B "$_branch" "origin/${_branch}"
      fi
    done
  else
    say "! git is still missing, so ~/.dotfiles is a plain copy without prezto."
    say "  Install git and re-run this script's clone step, or clone ${DOTFILES_REMOTE} yourself."
  fi
fi

if [ "$(basename "${SHELL:-}")" != zsh ] && has zsh; then
  say "→ Your login shell is ${SHELL:-unknown}; this setup is for zsh: chsh -s \"$(command -v zsh)\""
fi
