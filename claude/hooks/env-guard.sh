#!/bin/bash
# PreToolUse hook (Bash matcher): the single entry point for the env guards.
#
# One registered hook, one `jq` invocation, one pass over the command line —
# instead of one process per guarded tool on *every* Bash tool call. The
# per-tool knowledge lives in guards/*.guard profiles, which this script sources
# in turn; adding a tool is a new profile file and nothing else.
#
# A profile declares (all optional except GUARD_BINS):
#
#   GUARD_BINS        space-separated binaries the profile guards ("terraform tofu")
#   GUARD_STYLE       vocab | positional | sql  — how the action verb is found
#   GUARD_VOCAB       vocab style: every subcommand the tool knows, read or write
#   GUARD_VALFLAGS    vocab style: flags that consume the following word
#   GUARD_DESTRUCTIVE alternation of state-mutating verbs
#   GUARD_READONLY    positional style: read verbs, so one appearing before a
#                     destructive word wins (`openstack server list` on a host
#                     called "restart-me")
#   GUARD_BOOLS       positional style: flags that must NOT swallow the next word
#   GUARD_DRYRUN      alternation of flags that make this invocation persist nothing
#   GUARD_SAFE_TARGET regex; a resolved target matching it passes through
#   GUARD_REASON_TAIL sentence appended to the default prompt reason
#   GUARD_HELP_TOKENS alternation guard_is_help treats as a help flag; default
#                     '--help|-h|-help' — a profile whose `-h` means something
#                     else (mysql/psql: --host) overrides it
#
#   guard_resolve_target()  prints the target of the current segment ($GUARD_SEG)
#   guard_classify_extra()  vocab/positional: optional, 0 = destructive (sets
#                           GUARD_ACTION), 1 = read-only, 2 = no opinion, apply
#                           the default check. sql style: required — it IS the
#                           classifier, since there is no vocab/positional verb
#                           to fall back to (see mysql.guard/psql.guard).
#   guard_reason()          optional; prints the whole prompt reason, given the
#                           resolved target as $1
#
# See guard-lib.sh for how a command line is split and how a subcommand is
# identified without tripping on release names, file paths and flag values.
#
# A prompt that is about to fire is checked against the user's per-project
# allowlist first (guard_allowed), so a disposable target — the benchmark
# database, the kind cluster — can be pre-approved for one checkout without
# weakening any profile. The file is only read at that point, never on the
# common path.
set -u

GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GUARD_DIR/guard-lib.sh"

GUARD_INPUT=$(guard_input) || exit 0
# No newline back means no command field at all (a non-Bash tool call).
case "$GUARD_INPUT" in
  *'
'*) GUARD_CWD="${GUARD_INPUT%%'
'*}"; GUARD_CMD="${GUARD_INPUT#*'
'}" ;;
  *) exit 0 ;;
esac
[ -n "$GUARD_CMD" ] || exit 0
# The project the command runs in, for guard_allowed. Every hook payload
# carries it; the fallback is for running this script by hand.
[ -n "$GUARD_CWD" ] || GUARD_CWD="$PWD"
# Pre-strip copy: a profile whose payload IS its heredoc body (mysql/psql SQL,
# not YAML/values data) reconstructs it from this via guard_heredoc_body_for.
GUARD_RAW_CMD="$GUARD_CMD"

# Heredoc bodies are data being written, not commands being run — strip them
# before anything else looks at the command line. Guarded by a glob so the
# common case pays nothing.
case "$GUARD_CMD" in
  *'<<'*) GUARD_CMD=$(guard_strip_heredocs "$GUARD_CMD") ;;
esac

# Segment once for all profiles, and add the contents of any script the command
# executes, so `bash deploy.sh` is judged on what deploy.sh actually does.
GUARD_ALL_SEGMENTS=$(guard_segments "$GUARD_CMD")
GUARD_ALL_SEGMENTS="$GUARD_ALL_SEGMENTS
$(guard_script_bodies "$GUARD_ALL_SEGMENTS")
$(guard_make_recipes "$GUARD_ALL_SEGMENTS")"

# guard-lib turns globbing off (untrusted word-splitting); turn it back on just
# long enough to enumerate the profiles.
set +f
GUARD_PROFILES=()
for f in "$GUARD_DIR"/guards/*.guard; do
  [ -r "$f" ] && GUARD_PROFILES[${#GUARD_PROFILES[@]}]="$f"
done
set -f
[ ${#GUARD_PROFILES[@]} -gt 0 ] || exit 0

guard_is_fn() { declare -F "$1" >/dev/null 2>&1; }

# Profiles are sourced into this shell one after another, so anything the
# previous one defined has to go first — otherwise a profile without a
# guard_classify_extra silently inherits the last one's.
guard_profile_reset() {
  unset -f guard_classify_extra guard_resolve_target guard_reason
  GUARD_BINS=''
  GUARD_BIN=''
  GUARD_STYLE='vocab'
  GUARD_VOCAB=''
  GUARD_VALFLAGS=''
  GUARD_DESTRUCTIVE=''
  GUARD_READONLY=''
  GUARD_BOOLS=''
  GUARD_DRYRUN=''
  GUARD_SAFE_TARGET=''
  GUARD_REASON_TAIL='Explicit user confirmation required.'
  GUARD_ACTION=''
  GUARD_SEG=''
  GUARD_HELP_TOKENS='--help|-h|-help'
}

guard_default_reason() {
  printf 'Destructive %s "%s" targets %s. %s' \
    "$GUARD_BIN" "$GUARD_ACTION" "$1" "$GUARD_REASON_TAIL"
}

# 0 when the current invocation (GUARD_ARGS) mutates state; GUARD_ACTION names it.
guard_classify() {
  local rc verb
  GUARD_ACTION=''
  guard_is_help && return 1

  case "$GUARD_STYLE" in
    vocab)
      # Exact token match against the tool's full vocabulary, so a read-only
      # subcommand shields everything after it: `helm template test chart` is a
      # template render, not `helm test`.
      guard_subcommand "$GUARD_VOCAB" "$GUARD_VALFLAGS" || return 1
      if guard_is_fn guard_classify_extra; then
        guard_classify_extra; rc=$?
        [ $rc -eq 0 ] && return 0
        [ $rc -eq 1 ] && return 1
      fi
      [[ "$GUARD_SUB" =~ ^($GUARD_DESTRUCTIVE)$ ]] || return 1
      GUARD_ACTION="$GUARD_SUB"
      ;;
    positional)
      # Object-verb grammars (`openstack server delete`, `argocd app sync`) have
      # no fixed subcommand list, so the verb is looked for among positional
      # words only — `--revision sync-test` and an app named `my-app-set` are
      # flag values, not verbs.
      guard_positionals "$GUARD_BOOLS"
      if guard_is_fn guard_classify_extra; then
        guard_classify_extra; rc=$?
        [ $rc -eq 0 ] && return 0
        [ $rc -eq 1 ] && return 1
      fi
      verb=$(guard_pos_match "${GUARD_DESTRUCTIVE}|${GUARD_READONLY}") || return 1
      [[ "$verb" =~ ^($GUARD_DESTRUCTIVE)$ ]] || return 1
      GUARD_ACTION="$verb"
      ;;
    sql)
      # No subcommand vocabulary and no fixed verb position — the verb is a
      # SQL keyword that can appear in an -e/-c value, a heredoc body or a
      # redirected file, never in argv itself. guard_classify_extra is not
      # optional for this style; it IS the classifier (mysql.guard/psql.guard).
      if guard_is_fn guard_classify_extra; then
        guard_classify_extra; rc=$?
        [ $rc -eq 0 ] && return 0
        [ $rc -eq 1 ] && return 1
      fi
      return 1
      ;;
    *)
      return 1 ;;
  esac
  return 0
}

for guard_profile in "${GUARD_PROFILES[@]}"; do
  guard_profile_reset
  . "$guard_profile"
  [ -n "$GUARD_BINS" ] || continue

  # Cheap pre-filter: most Bash calls (ls, npm, cargo) mention none of the
  # guarded binaries and skip the whole profile without a single fork. Matched
  # against the expanded segments, not the raw command line — `bash deploy.sh`
  # never says "kubectl", but the script it runs does.
  guard_hit=0
  for guard_b in $GUARD_BINS; do
    case "$GUARD_ALL_SEGMENTS" in *"$guard_b"*) guard_hit=1; break ;; esac
  done
  [ $guard_hit -eq 1 ] || continue

  # Every segment is classified, dry-run-checked and target-resolved on its own.
  # Judging the whole command line by whichever mutation happens to be written
  # first is how `kubectl --context orbstack apply -f a.yml && kubectl --context
  # production apply -f b.yml` gets the production apply approved on the
  # strength of the local one.
  while IFS= read -r guard_seg; do
    [ -n "$guard_seg" ] || continue
    GUARD_SEG="$guard_seg"

    for guard_b in $GUARD_BINS; do
      guard_reaches "$guard_b" "$guard_seg" || continue
      GUARD_BIN="$guard_b"

      [ -n "$GUARD_DRYRUN" ] && guard_dry_run "$GUARD_DRYRUN" && continue
      guard_classify || continue

      if guard_is_fn guard_resolve_target; then
        guard_target=$(guard_resolve_target)
      else
        guard_target='unknown'
      fi

      if [ -n "$GUARD_SAFE_TARGET" ] \
         && printf '%s' "$guard_target" | grep -qE "$GUARD_SAFE_TARGET"; then
        continue
      fi

      # A target the user pre-approved for this project — the throwaway
      # benchmark database, the kind cluster. See guard_allowed in guard-lib.sh.
      guard_allowed "$GUARD_BIN" "$GUARD_ACTION" "$guard_target" && continue

      if guard_is_fn guard_reason; then
        guard_ask "$(guard_reason "$guard_target")"
      else
        guard_ask "$(guard_default_reason "$guard_target")"
      fi
    done
  done <<EOF
$GUARD_ALL_SEGMENTS
EOF
done

exit 0
