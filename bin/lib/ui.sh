# Output, prompts and dry-run support for bin/dotfiles and bin/_macos.
# POSIX sh: this has to run on a fresh Mac and on servers without zsh or bash.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_blue=$(printf '\033[34m'); _c_green=$(printf '\033[32m')
  _c_yellow=$(printf '\033[33m'); _c_magenta=$(printf '\033[35m')
  _c_red=$(printf '\033[31m'); _c_cyan=$(printf '\033[36m')
  _c_reset=$(printf '\033[0m')
else
  _c_blue=; _c_green=; _c_yellow=; _c_magenta=; _c_red=; _c_cyan=; _c_reset=
fi

print_header()   { printf '\n%s%s%s\n' "$_c_blue" "$*" "$_c_reset"; }
print_success()  { printf '%s✓ %s%s\n' "$_c_green" "$*" "$_c_reset"; }
print_notice()   { printf '%si %s%s\n' "$_c_yellow" "$*" "$_c_reset"; }
print_warning()  { printf '%s! %s%s\n' "$_c_magenta" "$*" "$_c_reset" >&2; }
print_error()    { printf '%sx %s%s\n' "$_c_red" "$*" "$_c_reset" >&2; }

abort() {
  print_error "$1"
  exit "${2:-1}"
}

# Yes/no question that always waits for a human. Reads /dev/tty rather than
# stdin, because under `curl … | sh` stdin is the script itself. With no
# terminal to ask on, the answer is no.
ask() {
  printf '%s? %s (y/n)%s ' "$_c_cyan" "$1" "$_c_reset"
  if ! { read -r _reply < /dev/tty; } 2>/dev/null; then
    printf '\n'
    return 1
  fi
  case "$_reply" in [Yy]|[Yy][Ee][Ss]) return 0 ;; esac
  return 1
}

# read_input <question> [default]: free-text answer in $INPUT, from /dev/tty
# for the same reason as ask. Empty input takes the default; with no terminal
# $INPUT is the default and the return status is 1.
read_input() {
  INPUT=
  printf '%s? %s%s%s ' "$_c_cyan" "$1" "${2:+ [$2]}" "$_c_reset"
  if ! { read -r INPUT < /dev/tty; } 2>/dev/null; then
    printf '\n'
    INPUT="${2:-}"
    return 1
  fi
  [ -n "$INPUT" ] || INPUT="${2:-}"
  return 0
}

# pause <message>: wait for Enter while the user does something by hand (a
# sign-in). Not a question, so --yes does not skip it; with no terminal, or
# under --dry-run, there is nobody to wait for and it returns at once.
pause() {
  print_notice "$1"
  [ -z "${DOTFILES_DRY_RUN:-}" ] || return 0
  printf '%s  Press Enter to continue.%s ' "$_c_cyan" "$_c_reset"
  { read -r _reply < /dev/tty; } 2>/dev/null || printf '\n'
}

# Like ask, but --yes (DOTFILES_YES=1) answers it.
confirm() {
  if [ -n "${DOTFILES_YES:-}" ]; then
    printf '%s? %s (y/n)%s y (--yes)\n' "$_c_cyan" "$1" "$_c_reset"
    return 0
  fi
  ask "$1"
}

# Run a command that changes something, or only print it under --dry-run.
run() {
  if [ -n "${DOTFILES_DRY_RUN:-}" ]; then
    printf '  would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

# run, but without the command's own output — which a plain `run … >/dev/null`
# would take down together with the --dry-run line.
run_quiet() {
  if [ -n "${DOTFILES_DRY_RUN:-}" ]; then
    run "$@"
    return 0
  fi
  "$@" </dev/null >/dev/null 2>&1
}

has() { command -v "$1" >/dev/null 2>&1; }
is_macos() { [ "$(uname -s)" = Darwin ]; }
is_linux() { [ "$(uname -s)" = Linux ]; }
