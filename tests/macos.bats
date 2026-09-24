#!/usr/bin/env bats
#
# Behaviour tests for bin/lib/macos.sh, the idempotent setting helpers that
# bin/_macos is built on.
#
#   brew install bats-core
#   bats tests/macos.bats
#
# The rule under test: a setting already in place is not written again and is
# not counted as a change. Counting it would be the visible bug — bin/_macos
# ends in Dock, Finder and SystemUIServer restarts gated on MACOS_CHANGES, so
# a helper that reports a change on every run blanks the desktop on every run.
#
# Every case that writes anything writes to a scratch plist in
# $BATS_TEST_TMPDIR. The cases against real domains are read-only: they take
# the machine's current value and assert that writing it back is skipped.

bats_require_minimum_version 1.5.0

setup() {
  # shellcheck source=../bin/lib/macos.sh
  . "${BATS_TEST_DIRNAME}/../bin/lib/macos.sh"
  DOMAIN="${BATS_TEST_TMPDIR}/scratch"
}

# The helpers are called directly and never through bats' `run`: `run` is a
# subshell, so every MACOS_CHANGES assertion made after it would compare the
# counter against itself and pass no matter what the helper did.

# Asserts the helper skipped: non-zero status and no change counted.
assert_skipped() {
  local before=$MACOS_CHANGES status=0
  "$@" > /dev/null || status=$?
  [ "$status" -ne 0 ]
  [ "$MACOS_CHANGES" -eq "$before" ]
}

# Asserts the helper acted: zero status and exactly one change counted.
assert_applied() {
  local before=$MACOS_CHANGES status=0
  "$@" > /dev/null || status=$?
  [ "$status" -eq 0 ]
  [ "$MACOS_CHANGES" -eq $((before + 1)) ]
}

@test "a value that is not set yet is written" {
  assert_applied set_default "$DOMAIN" flag -bool true
  [ "$(defaults read "$DOMAIN" flag)" = 1 ]
}

@test "the same bool a second time is skipped" {
  set_default "$DOMAIN" flag -bool true
  assert_skipped set_default "$DOMAIN" flag -bool true
}

# `defaults read` answers 1, `defaults write` takes `true`. Comparing the
# argument as written would rewrite all 130 booleans in bin/_macos every run.
@test "a stored 1 counts as matching -bool true" {
  defaults write "$DOMAIN" flag -bool true
  assert_skipped set_default "$DOMAIN" flag -bool true
}

@test "a stored 0 counts as matching -bool false" {
  defaults write "$DOMAIN" flag -bool false
  assert_skipped set_default "$DOMAIN" flag -bool false
}

@test "flipping a bool is applied" {
  set_default "$DOMAIN" flag -bool true
  assert_applied set_default "$DOMAIN" flag -bool false
  [ "$(defaults read "$DOMAIN" flag)" = 0 ]
}

@test "an int that differs is applied, the same int is skipped" {
  assert_applied set_default "$DOMAIN" count -int 3
  assert_skipped set_default "$DOMAIN" count -int 3
  assert_applied set_default "$DOMAIN" count -int 4
  [ "$(defaults read "$DOMAIN" count)" = 4 ]
}

@test "a string with spaces is compared whole" {
  set_default "$DOMAIN" color -string "0.9 0.8 1.0"
  assert_skipped set_default "$DOMAIN" color -string "0.9 0.8 1.0"
  assert_applied set_default "$DOMAIN" color -string "0.9 0.8 0.5"
}

@test "a float round-trips through the comparison" {
  set_default "$DOMAIN" ratio -float 0.5
  assert_skipped set_default "$DOMAIN" ratio -float 0.5
}

# com.apple.print.PrintingPrefs "Quit When Finished" in bin/_macos.
@test "a key whose name contains spaces is handled" {
  set_default "$DOMAIN" "Quit When Finished" -bool true
  assert_skipped set_default "$DOMAIN" "Quit When Finished" -bool true
}

@test "a dict-add that adds nothing new is not a change" {
  set_default_merged "$DOMAIN" dict -dict-add a -bool true
  assert_skipped set_default_merged "$DOMAIN" dict -dict-add a -bool true
}

@test "a dict-add of a second key is a change and keeps the first" {
  set_default_merged "$DOMAIN" dict -dict-add a -bool true
  assert_applied set_default_merged "$DOMAIN" dict -dict-add b -bool false
  assert_skipped set_default_merged "$DOMAIN" dict -dict-add a -bool true
}

@test "an array written twice is a change only the first time" {
  assert_applied set_default_merged "$DOMAIN" list -array 4
  assert_skipped set_default_merged "$DOMAIN" list -array 4
}

@test "macos_changed is what the restart gate counts" {
  [ "$MACOS_CHANGES" -eq 0 ]
  assert_applied set_default "$DOMAIN" a -int 1
  assert_applied set_default "$DOMAIN" b -int 1
  assert_skipped set_default "$DOMAIN" a -int 1
  [ "$MACOS_CHANGES" -eq 2 ]
}

# -currentHost is a separate store, ~/Library/Preferences/ByHost. The flag has
# to be on the read as much as on the write: com.apple.ImageCapture
# disableHotPlug, one of the four -currentHost settings in bin/_macos, lives
# only there. Reading it without the flag finds nothing, so a helper that
# dropped the flag would see no match and rewrite it on every run.
#
# A scratch plist cannot stand in for this — `defaults -currentHost write`
# refuses a file path outright — so the case reads the real store instead.
@test "currentHost reads the store it writes to" {
  local byhost
  byhost=$(defaults -currentHost read com.apple.ImageCapture disableHotPlug 2>/dev/null) ||
    skip "disableHotPlug is not set in this machine's ByHost store"
  run -1 defaults read com.apple.ImageCapture disableHotPlug
  if [ "$byhost" = 1 ]; then
    assert_skipped set_default_currenthost com.apple.ImageCapture disableHotPlug -bool true
  else
    assert_skipped set_default_currenthost com.apple.ImageCapture disableHotPlug -bool false
  fi
}

@test "a real preference already at its value is skipped" {
  local tilesize
  tilesize=$(defaults read com.apple.dock tilesize)
  assert_skipped set_default com.apple.dock tilesize -int "$tilesize"
}

@test "a real bool already at its value is skipped" {
  local autohide
  autohide=$(defaults read com.apple.dock autohide)
  if [ "$autohide" = 1 ]; then
    assert_skipped set_default com.apple.dock autohide -bool true
  else
    assert_skipped set_default com.apple.dock autohide -bool false
  fi
}

@test "pmset_is matches the value the machine reports" {
  local want
  want=$(pmset -g custom | awk '/^AC Power:/{a=1;next} /^Battery Power:/{a=0} a && $1=="sleep"{print $2}')
  [ -n "$want" ] || skip "this machine does not report an AC sleep setting"
  run -0 pmset_is -c sleep "$want"
  run -1 pmset_is -c sleep 99999
}

# lidwake and autorestart are absent from `pmset -g custom` on Apple silicon
# laptops. set_pmset writes them anyway but must not claim a change, or every
# run ends in the app restarts.
@test "pmset_is does not claim a setting the machine never reports" {
  pmset -g custom | grep -q lidwake && skip "this machine reports lidwake"
  run -1 pmset_is -a lidwake 1
}

@test "logout_if_changed stays quiet when its section did nothing" {
  assert_applied set_default "$DOMAIN" flag -int 1
  local before=$MACOS_CHANGES
  assert_skipped set_default "$DOMAIN" flag -int 1
  logout_if_changed "$before" "keyboard repeat" || true
  [ -z "$MACOS_LOGOUT_FOR" ]
}

@test "logout_if_changed names the section that moved" {
  local before=$MACOS_CHANGES
  assert_applied set_default "$DOMAIN" flag -int 1
  logout_if_changed "$before" "keyboard repeat"
  [ "$MACOS_LOGOUT_FOR" = "keyboard repeat" ]
}

@test "logout_if_changed accumulates several sections" {
  local before=$MACOS_CHANGES
  assert_applied set_default "$DOMAIN" a -int 1
  logout_if_changed "$before" "trackpad and mouse"
  before=$MACOS_CHANGES
  assert_applied set_default "$DOMAIN" b -int 1
  logout_if_changed "$before" "keyboard repeat"
  [ "$MACOS_LOGOUT_FOR" = "trackpad and mouse, keyboard repeat" ]
}

@test "set_nohidden skips a directory that is already visible" {
  mkdir -p "${BATS_TEST_TMPDIR}/visible"
  assert_skipped set_nohidden "${BATS_TEST_TMPDIR}/visible"
}

@test "set_nohidden clears the flag on a hidden directory" {
  mkdir -p "${BATS_TEST_TMPDIR}/hidden"
  chflags hidden "${BATS_TEST_TMPDIR}/hidden"
  assert_applied set_nohidden "${BATS_TEST_TMPDIR}/hidden"
  [ -z "$(find "${BATS_TEST_TMPDIR}/hidden" -maxdepth 0 -flags +hidden)" ]
}

@test "set_default_app skips the handler that is already registered" {
  local current
  current=$(duti -d public.plain-text 2>/dev/null) || skip "duti is not installed"
  [ -n "$current" ] || skip "no handler registered for public.plain-text"
  assert_skipped set_default_app "$current" public.plain-text
}
