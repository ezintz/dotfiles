# Idempotent system settings for bin/_macos. POSIX sh like the rest of
# bin/lib, because bin/_macos runs as `sh bin/_macos`.
#
# Every helper here asks "is this already the case?" before it acts. That is
# what lets bin/dotfiles be run on a whim: a machine that already matches gets
# no writes, no output, and none of the app restarts at the end of bin/_macos.
# Applying a setting that is already set is not free — it dirties the
# preference, and the Dock, Finder and SystemUIServer restarts that follow are
# visible, so an unconditional run costs a flickering desktop every time.

## Settings actually changed this run. The restarts at the end of bin/_macos
## are gated on it, and a section that has its own app to restart compares it
## against the value it saved before the section started.
MACOS_CHANGES=0

## Records a change and names it. Nothing prints when nothing moves, so
## silence from bin/_macos means the machine already matched.
macos_changed() {
  MACOS_CHANGES=$((MACOS_CHANGES + 1))
  printf '  %s\n' "$*"
}

## What, if anything, now needs a logout — empty means nothing does.
MACOS_LOGOUT_FOR=

## logout_if_changed <counter saved before the section> <what it was>
##
## Almost nothing in bin/_macos needs a logout: the app that reads the setting
## is restarted at the bottom of the file. The exceptions are the settings
## whose consumer is WindowServer or loginwindow, which read them once at
## login and cannot be restarted short of one — keyboard repeat, full keyboard
## access, press-and-hold, the zoom modifiers, and the trackpad and mouse
## keys. A section that owns such settings saves MACOS_CHANGES before them and
## calls this after, so the closing message names what is actually waiting on
## a logout instead of warning about one unconditionally.
logout_if_changed() {
  [ "$MACOS_CHANGES" -eq "$1" ] && return 1
  shift
  MACOS_LOGOUT_FOR="${MACOS_LOGOUT_FOR:+${MACOS_LOGOUT_FOR}, }$*"
}

## set_default <domain> <key> <-type> <value>
## set_default_currenthost <domain> <key> <-type> <value>
##
## `defaults write` that runs only when the stored value differs.
##
## The comparison is against what `defaults read` prints, which is not what
## `defaults write` accepts: a boolean reads back as 1 or 0 and never as
## `true`, so comparing the argument as written would rewrite all 130 booleans
## in bin/_macos on every run.
##
## -currentHost is a different store — the per-machine one under
## ~/Library/Preferences/ByHost — and the flag has to be on the read as much
## as on the write. Reading NSGlobalDomain without it answers from the shared
## store, where the key is usually absent, so every run would look like a
## change and write again.
##
## Scalars only. -array, -dict and -dict-add build their value out of what is
## already stored, so the result cannot be worked out from the arguments;
## those go through set_default_merged.
set_default() { _set_default '' "$@"; }
set_default_currenthost() { _set_default -currentHost "$@"; }

# shellcheck disable=SC2086 # _sd_scope is -currentHost or nothing at all
_set_default() {
  _sd_scope=$1 _sd_domain=$2 _sd_key=$3 _sd_type=$4 _sd_value=$5
  _sd_want=$_sd_value

  case $_sd_type in
    -bool | -boolean)
      case $_sd_value in
        true | yes | 1) _sd_want=1 ;;
        *) _sd_want=0 ;;
      esac
      ;;
  esac

  _sd_have=$(defaults $_sd_scope read "$_sd_domain" "$_sd_key" 2>/dev/null) || _sd_have=
  [ "$_sd_have" = "$_sd_want" ] && return 1

  defaults $_sd_scope write "$_sd_domain" "$_sd_key" "$_sd_type" "$_sd_value" || return 1
  macos_changed "$_sd_domain $_sd_key = $_sd_value"
}

## set_default_merged <domain> <key> <defaults write arguments…>
## sudo_set_default_merged <domain> <key> <defaults write arguments…>
##
## For -array, -dict and -dict-add, which merge with what is already stored
## and so have nothing to compare against beforehand. The write happens either
## way — it lands the same bytes when the value already matches — and the
## value read before and after decides whether this counted as a change.
set_default_merged() { _set_default_merged '' "$@"; }
sudo_set_default_merged() { _set_default_merged sudo "$@"; }

# shellcheck disable=SC2086 # _sdm_run is a bare `sudo` or nothing at all
_set_default_merged() {
  _sdm_run=$1 _sdm_domain=$2 _sdm_key=$3
  shift 3

  _sdm_before=$($_sdm_run defaults read "$_sdm_domain" "$_sdm_key" 2>/dev/null) || _sdm_before=
  $_sdm_run defaults write "$_sdm_domain" "$_sdm_key" "$@" || return 1
  _sdm_after=$($_sdm_run defaults read "$_sdm_domain" "$_sdm_key" 2>/dev/null) || _sdm_after=

  [ "$_sdm_before" = "$_sdm_after" ] && return 1
  macos_changed "$_sdm_domain $_sdm_key"
}

## pmset_is <-a|-b|-c> <setting> <value>
##
## True when the blocks the flag writes to already report that value.
## `pmset -g custom` prints a Battery Power and an AC Power block, so which
## ones have to match depends on the flag: -a sets both, -b and -c one each.
pmset_is() {
  pmset -g custom 2>/dev/null | awk -v flag="$1" -v key="$2" -v want="$3" '
    /^Battery Power:/ { block = "b"; next }
    /^AC Power:/      { block = "c"; next }
    $1 == key         { seen[block] = $2 }
    END {
      if (flag == "-b") exit !(("b" in seen) && seen["b"] == want)
      if (flag == "-c") exit !(("c" in seen) && seen["c"] == want)
      exit !(("b" in seen) && ("c" in seen) && seen["b"] == want && seen["c"] == want)
    }'
}

## set_pmset <-a|-b|-c> <setting> <value>
##
## A setting the machine does not report at all is written and then still does
## not read back — `lidwake` and `autorestart` are absent from `pmset -g
## custom` on Apple silicon laptops. That write is deliberately not counted as
## a change: it cannot be confirmed, so counting it would mean every run ends
## in the Dock and Finder restarts at the bottom of bin/_macos. Nothing reads
## a power setting that needs restarting anyway.
set_pmset() {
  pmset_is "$@" && return 1

  sudo pmset "$1" "$2" "$3" || return 1
  pmset_is "$@" || return 1
  macos_changed "pmset $1 $2 $3"
}

## set_nohidden <path>
##
## chflags says nothing about whether it had anything to do, so the flag is
## read first. BSD find matches on it directly with -flags; `ls -lO` would
## mean parsing a column out of ls.
set_nohidden() {
  [ -n "$(find "$1" -maxdepth 0 -flags +hidden 2>/dev/null)" ] || return 1

  case $1 in
    /Volumes | /Volumes/*) sudo chflags nohidden "$1" || return 1 ;;
    *) chflags nohidden "$1" || return 1 ;;
  esac
  macos_changed "chflags nohidden $1"
}

## set_default_app <bundle id> <uti>
##
## duti -d answers with the bundle id currently handling the UTI.
set_default_app() {
  [ "$(duti -d "$2" 2>/dev/null)" = "$1" ] && return 1

  duti -s "$1" "$2" all || return 1
  macos_changed "$2 opens in $1"
}
