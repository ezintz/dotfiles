# Backing the private overlay ($DOTFILES_LOCAL_DIRECTORY) up to a private repo,
# and restoring it on a new machine. Sourced by bin/dotfiles.
#
# One repo per machine, dotfiles-overlay-<machine id>: every machine has its
# own zprofile, gitauthor and settings, and a shared repo would have them all
# pushing into the same files. A new machine has no repo of its own yet, so it
# is offered the other machines' repos to seed from.
#
# The forge is picked interactively, or set for unattended runs and tests:
#   DOTFILES_OVERLAY_FORGE         github | gitlab | gitea | url
#   DOTFILES_OVERLAY_URL           url forge: this machine's repo
#   DOTFILES_OVERLAY_RESTORE_FROM  url forge: a repo to seed from, or "none"
#   DOTFILES_OVERLAY_PUSH=1        commit and push overlay changes unasked
# Setting DOTFILES_OVERLAY_FORGE is the opt-in, so it skips the first question.

OVERLAY_PREFIX="dotfiles-overlay-"

# The hardware serial: stable across reinstalls and hostname changes. Linux
# only exposes the serial to root, so the machine-id (per installation) stands
# in there.
machine_id() {
  _id=
  if is_macos; then
    _id=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null |
      sed -n 's/.*"IOPlatformSerialNumber" = "\(.*\)"/\1/p')
  elif [ -r /etc/machine-id ]; then
    _id=$(cut -c1-12 /etc/machine-id)
  fi
  [ -n "$_id" ] || _id=$(hostname -s 2>/dev/null || hostname)
  printf '%s' "$_id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-'
}

machine_description() {
  if is_macos; then
    printf 'dotfiles overlay for %s (%s)' "$(scutil --get LocalHostName 2>/dev/null || hostname -s)" "$(sysctl -n hw.model)"
  else
    printf 'dotfiles overlay for %s (%s)' "$(hostname -s 2>/dev/null || hostname)" "$(uname -sm)"
  fi
}

pick_forge() {
  _default=url
  for _f in gitea gitlab github; do
    forge_logged_in "$_f" && _default="$_f"
  done
  printf '  1) GitHub   2) GitLab   3) Gitea / Forgejo   4) any git URL\n'
  read_input "Where should the private repository live?" "$_default"
  case "$INPUT" in
    1|github|GitHub) FORGE=github ;;
    2|gitlab|GitLab) FORGE=gitlab ;;
    3|gitea|forgejo|Gitea) FORGE=gitea ;;
    4|url) FORGE=url ;;
    *) FORGE="$_default" ;;
  esac
}

forge_logged_in() {
  case "$1" in
    github) has gh && gh auth status >/dev/null 2>&1 ;;
    gitlab) has glab && glab auth status >/dev/null 2>&1 ;;
    gitea) has tea && [ -n "$(tea logins list --output simple 2>/dev/null)" ] ;;
    *) return 1 ;;
  esac
}

# Make sure the CLI is there and logged in; the login is interactive.
forge_ready() {
  case "$1" in
    github) _cli=gh ;; gitlab) _cli=glab ;; gitea) _cli=tea ;; *) return 0 ;;
  esac
  has "$_cli" || { print_warning "${_cli} is not installed (it comes from the Brewfile)."; return 1; }
  if ! forge_logged_in "$1"; then
    print_notice "Log in to ${1} with ${_cli} ..."
    case "$1" in
      github) gh auth login < /dev/tty ;;
      gitlab) glab auth login < /dev/tty ;;
      gitea) tea login add < /dev/tty ;;
    esac || return 1
  fi
  # So a plain `git push` over https uses the CLI's token.
  [ "$1" = github ] && gh auth setup-git >/dev/null 2>&1
  return 0
}

# forge_url <forge> <name>: clone URL of an existing repo, or nothing.
forge_url() {
  case "$1" in
    github)
      _owner=$(gh api user --jq .login) || return 1
      if [ "$(gh config get git_protocol 2>/dev/null)" = ssh ]; then _field=sshUrl; else _field=url; fi
      gh repo view "${_owner}/$2" --json "$_field" --jq ".${_field}" 2>/dev/null ;;
    gitlab)
      _owner=$(glab api user 2>/dev/null | jq -r .username) || return 1
      glab api "projects/${_owner}%2F$2" 2>/dev/null | jq -r '.http_url_to_repo // empty' ;;
    gitea)
      forge_list gitea | awk -F '\t' -v n="$2" '$1 == n { print $2 }' ;;
    url)
      [ -n "${DOTFILES_OVERLAY_URL:-}" ] || return 0
      git ls-remote "$DOTFILES_OVERLAY_URL" >/dev/null 2>&1 && printf '%s' "$DOTFILES_OVERLAY_URL" ;;
  esac
}

# forge_list <forge>: "name<TAB>clone url<TAB>description" per overlay repo.
forge_list() {
  case "$1" in
    github)
      _owner=$(gh api user --jq .login) || return 0
      if [ "$(gh config get git_protocol 2>/dev/null)" = ssh ]; then _field=sshUrl; else _field=url; fi
      gh repo list "$_owner" --limit 1000 --json name,description,url,sshUrl \
        --jq ".[] | select(.name | startswith(\"${OVERLAY_PREFIX}\")) | [.name, .${_field}, (.description // \"\")] | @tsv" ;;
    gitlab)
      glab repo list --mine -F json -P 100 2>/dev/null |
        jq -r ".[] | select(.path | startswith(\"${OVERLAY_PREFIX}\")) | [.path, .http_url_to_repo, (.description // \"\")] | @tsv" ;;
    gitea)
      tea repos ls --output json --fields name,ssh,description --limit 200 2>/dev/null |
        jq -r ".[] | select(.name | startswith(\"${OVERLAY_PREFIX}\")) | [.name, .ssh, (.description // \"\")] | @tsv" ;;
  esac
}

# forge_create <forge> <name> <description>: create the private repo, print its URL.
forge_create() {
  case "$1" in
    github) run gh repo create "$2" --private --description "$3" >&2 ;;
    gitlab) run glab repo create "$2" --private --description "$3" --defaultBranch main >&2 ;;
    gitea) run tea repos create --name "$2" --private --description "$3" >&2 ;;
    url) return 1 ;;
  esac || return 1
  [ -n "${DOTFILES_DRY_RUN:-}" ] && { printf 'https://example.invalid/%s.git' "$2"; return 0; }
  forge_url "$1" "$2"
}

overlay_is_empty() {
  [ ! -d "$DOTFILES_LOCAL_DIRECTORY" ] || [ -z "$(ls -A "$DOTFILES_LOCAL_DIRECTORY" 2>/dev/null)" ]
}

# Copy the files of another machine's overlay in, never over a file already here.
seed_overlay_from() {
  _tmp="${DOTFILES_LOCAL_DIRECTORY}.seed-$$"
  run git clone -q "$1" "$_tmp" || { print_warning "Could not clone $1"; return 1; }
  [ -n "${DOTFILES_DRY_RUN:-}" ] && return 0
  (cd "$_tmp" && find . -path ./.git -prune -o -type f -print) | while read -r _f; do
    _f="${_f#./}"
    [ -e "${DOTFILES_LOCAL_DIRECTORY}/${_f}" ] && continue
    mkdir -p "$(dirname "${DOTFILES_LOCAL_DIRECTORY}/${_f}")"
    cp -p "${_tmp}/${_f}" "${DOTFILES_LOCAL_DIRECTORY}/${_f}"
  done
  rm -rf "$_tmp"
}

# Commit identity for the overlay's own commits: the configured one, or a
# neutral stand-in on a machine whose Git identity is not set up yet (setup_git
# runs later and writes it into this very overlay).
overlay_git() {
  if git -C "$DOTFILES_LOCAL_DIRECTORY" config user.email >/dev/null 2>&1; then
    run git -C "$DOTFILES_LOCAL_DIRECTORY" "$@"
  else
    run git -C "$DOTFILES_LOCAL_DIRECTORY" -c user.name="dotfiles" -c user.email="dotfiles@$(hostname -s 2>/dev/null || hostname)" "$@"
  fi
}

setup_overlay() {
  [ -d "${DOTFILES_LOCAL_DIRECTORY}/.git" ] && return 0
  has git || return 0

  FORGE="${DOTFILES_OVERLAY_FORGE:-}"
  if [ -z "$FORGE" ]; then
    print_header "Private overlay backup"
    if ! ask "Back up your local files (${DOTFILES_LOCAL_DIRECTORY}) to a private repository?"; then
      print_notice "Not backed up. Run 'dotfiles --no-packages --no-configuration' again to set it up later."
      return 0
    fi
    pick_forge
  fi
  forge_ready "$FORGE" || { print_warning "Skipping the overlay backup."; return 0; }

  _name="${OVERLAY_PREFIX}$(machine_id)"
  if [ "$FORGE" = url ] && [ -z "${DOTFILES_OVERLAY_URL:-}" ]; then
    read_input "Clone URL of the private repository for this machine (create it first, e.g. ${_name})" ||
      { print_warning "No URL given; skipping the overlay backup."; return 0; }
    DOTFILES_OVERLAY_URL="$INPUT"
  fi
  _url=$(forge_url "$FORGE" "$_name")

  # This machine's own repo already has history: a reinstall. Take it as is.
  if [ -n "$_url" ] && [ -n "$(git ls-remote "$_url" 2>/dev/null)" ]; then
    if ! overlay_is_empty; then
      print_warning "${_url} already has this machine's overlay, and ${DOTFILES_LOCAL_DIRECTORY} is not empty."
      print_warning "Move one of them aside and re-run; nothing was merged."
      return 0
    fi
    print_notice "Restoring this machine's overlay from ${_url}"
    [ -d "$DOTFILES_LOCAL_DIRECTORY" ] && run rmdir "$DOTFILES_LOCAL_DIRECTORY"
    run git clone -q "$_url" "$DOTFILES_LOCAL_DIRECTORY"
    return 0
  fi

  # A new machine: offer another machine's overlay to start from.
  _seed="${DOTFILES_OVERLAY_RESTORE_FROM:-}"
  if [ -z "$_seed" ] && [ "$FORGE" != url ]; then
    _others=$(forge_list "$FORGE" | awk -F '\t' -v n="$_name" '$1 != n')
    if [ -n "$_others" ]; then
      printf '%s\n' "$_others" | awk -F '\t' '{ printf "  %d) %s  %s\n", NR, $1, $3 }'
      read_input "Start from one of these overlays (number), or empty for a fresh one" ""
      case "$INPUT" in
        ''|*[!0-9]*) _seed=none ;;
        *) _seed=$(printf '%s\n' "$_others" | awk -F '\t' -v i="$INPUT" 'NR == i { print $2 }') ;;
      esac
    fi
  elif [ -z "$_seed" ]; then
    read_input "Clone URL of another machine's overlay to start from (empty for a fresh one)" "" || true
    _seed="${INPUT:-none}"
  fi

  if [ -z "$_url" ]; then
    print_notice "Creating the private repository ${_name}"
    _url=$(forge_create "$FORGE" "$_name" "$(machine_description)") && [ -n "$_url" ] ||
      { print_warning "Could not create ${_name}; skipping the overlay backup."; return 0; }
  fi

  [ -d "$DOTFILES_LOCAL_DIRECTORY" ] || run mkdir -p "$DOTFILES_LOCAL_DIRECTORY"
  run git -C "$DOTFILES_LOCAL_DIRECTORY" init -q
  run git -C "$DOTFILES_LOCAL_DIRECTORY" symbolic-ref HEAD refs/heads/main
  if [ -n "$_seed" ] && [ "$_seed" != none ]; then
    print_notice "Seeding the overlay from ${_seed}"
    seed_overlay_from "$_seed"
  fi
  if [ -z "${DOTFILES_DRY_RUN:-}" ] && ! grep -qx 'secrets.env' "${DOTFILES_LOCAL_DIRECTORY}/.gitignore" 2>/dev/null; then
    printf '# Keys stay on the machine; they are re-entered, never pushed.\nsecrets.env\n.DS_Store\n' >> "${DOTFILES_LOCAL_DIRECTORY}/.gitignore"
  fi
  # A key added since migrate_overlay ran must not reach the first commit.
  migrate_overlay_secrets
  run git -C "$DOTFILES_LOCAL_DIRECTORY" add -A
  overlay_git commit -q -m "initial overlay for $(hostname -s 2>/dev/null || hostname)"
  run git -C "$DOTFILES_LOCAL_DIRECTORY" remote add origin "$_url"
  run git -C "$DOTFILES_LOCAL_DIRECTORY" push -q -u origin main ||
    print_warning "Could not push to ${_url}; the overlay is committed locally."
  print_success "Overlay backed up to ${_url}"
}

# At the end of a run: offer to commit and push whatever changed in the overlay.
# ask, not confirm: --yes answers routine questions, not publishing changes.
backup_overlay() {
  [ -d "${DOTFILES_LOCAL_DIRECTORY}/.git" ] || return 0
  # A key added to an rc file during this run moves out before anything is shown.
  migrate_overlay_secrets
  _changes=$(git -C "$DOTFILES_LOCAL_DIRECTORY" status --porcelain 2>/dev/null)
  [ -n "$_changes" ] || return 0

  # Belt and braces behind the overlay's .gitignore.
  if git -C "$DOTFILES_LOCAL_DIRECTORY" ls-files --error-unmatch secrets.env >/dev/null 2>&1 ||
     printf '%s\n' "$_changes" | grep -q 'secrets\.env$'; then
    print_error "secrets.env is tracked in ${DOTFILES_LOCAL_DIRECTORY}; not backing up. Untrack it first."
    return 0
  fi

  print_header "Private overlay changes"
  git -C "$DOTFILES_LOCAL_DIRECTORY" status --short
  if [ "${DOTFILES_OVERLAY_PUSH:-}" = 1 ] || ask "Commit and push these changes to the overlay repository?"; then
    run git -C "$DOTFILES_LOCAL_DIRECTORY" add -A
    overlay_git commit -q -m "backup from $(hostname -s 2>/dev/null || hostname) ($(date +%Y-%m-%d))"
    run git -C "$DOTFILES_LOCAL_DIRECTORY" push -q ||
      print_warning "Push failed; the backup is committed locally and goes out with the next one."
  fi
}
