#!/bin/bash
# Shared helpers for the Claude Code env-guard PreToolUse hooks.
# Sourced by kubectl/terraform/openstack/argocd-env-guard.sh — not executable
# on its own. Must stay bash 3.2 compatible (macOS /bin/bash).
#
# Why this exists
# ---------------
# The guards have to satisfy two goals at once:
#   1. never miss a genuinely state-mutating command, and
#   2. never prompt for a read-only inspection command.
#
# The first implementation matched "<binary> ... <destructive-verb>" anywhere in
# the command string. That fires on any verb-shaped word that happens to appear
# as a release name, file path, label value, flag value or grep pattern —
# `helm template test chart` was read as `helm test`, `kubectl rollout status`
# as a rollout mutation.
#
# These helpers instead:
#   * split the command line into simple-command segments,
#   * find the segments that actually *invoke* the binary (command word, after
#     env assignments and transparent wrappers),
#   * identify the real subcommand by exact token match against a known
#     vocabulary, skipping values of value-taking flags,
#   * and classify only that.
#
# Safety net: a segment that merely *mentions* the binary followed by a
# destructive verb — `sh -c "helm upgrade ..."`, eval, a wrapper script arg —
# still asks, via the old loose match (guard_wrapped_mention). So hiding a
# command inside a wrapper never gets you a free pass; it gets you a prompt.

set -u
set -f    # no globbing while word-splitting untrusted command strings

GUARD_JQ="$(command -v jq || echo /usr/bin/jq)"

GUARD_TOKENS=()
GUARD_ARGS=()
GUARD_POS=()
GUARD_SUB=""
GUARD_SUB_IDX=-1
# Command word of the segment when the binary was reached through a wrapper
# (empty for a direct invocation). Lets a hook notice that the command runs
# somewhere else entirely — `ssh host "kubectl …"`, `docker run … kubectl …` —
# where the local context/config says nothing about the real target.
GUARD_HEAD=""
GUARD_REMOTE_HEADS='ssh|scp|docker|podman|nerdctl|lima|colima|multipass|vagrant|ansible|ansible-playbook'

# --- input / output ---------------------------------------------------------

# Read the hook JSON on stdin, print .tool_input.command.
guard_input_command() {
  "$GUARD_JQ" -r '.tool_input.command // empty' 2>/dev/null
}

# Emit permissionDecision "ask" with <reason> and exit.
guard_ask() {
  "$GUARD_JQ" -cn --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# --- segmentation / tokenizing ----------------------------------------------

# Split a command line into rough simple-command segments, one per line.
# Over-splitting is harmless: a fragment that no longer starts with the binary
# is simply not treated as an invocation of it.
# The trailing newline matters: callers invoke this in a loop (one script body
# or one make recipe at a time) and append the results. Without it the last
# command of one body and the first of the next merge into a single line, and
# `bash a.sh && bash b.sh` ends up classifying `…/srv/appkubectl --context
# production delete …` — one token that matches no guard, so neither prompts.
guard_segments() {
  printf '%s\n' "$1" | tr $';|&(){}`\n' $'\n\n\n\n\n\n\n\n'
}

# guard_strip_heredocs <command> — the command with every heredoc *body*
# removed, keeping the line that opens it.
#
# A heredoc body is data being written somewhere, not a command being run.
# `cat > runbook.md <<'EOF' … kubectl --context production delete pod … EOF`
# documents a command; it does not execute one, and segmenting on newlines made
# every line of that body look like an invocation. Documenting a destructive
# command is the single most common way to trip a guard that has no idea the
# text is going into a file.
#
# The opening line is kept on purpose, because it can be a real command in its
# own right: `kubectl --context production apply -f - <<'EOF'` really does apply.
guard_strip_heredocs() {
  local line delim='' dashed=0 trimmed spec
  while IFS= read -r line; do
    if [ -n "$delim" ]; then
      trimmed="$line"
      # Only `<<-` permits an indented terminator, and only with tabs. Being
      # stricter than bash here would end the body early and hand the rest of
      # the document back to the classifier.
      if [ "$dashed" = 1 ]; then
        while [ "${trimmed#	}" != "$trimmed" ]; do trimmed="${trimmed#	}"; done
      fi
      [ "$trimmed" = "$delim" ] && delim=''
      continue
    fi
    printf '%s\n' "$line"
    # `<<<` is a herestring with no body, and `$((1<<3))` is a shift; neither
    # matches the delimiter pattern, so neither opens a body here.
    case "$line" in
      *'<<'*)
        spec=$(printf '%s' "$line" | sed -nE 's/.*<<(-?)[[:space:]]*("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([A-Za-z_][A-Za-z0-9_]*)).*/\1\3\4\5/p')
        case "$spec" in
          '') ;;
          -*) dashed=1; delim="${spec#-}" ;;
          *)  dashed=0; delim="$spec" ;;
        esac ;;
    esac
  done <<EOF
$1
EOF
}

# --- executed scripts -------------------------------------------------------

# guard_script_path <segment> — the script file this segment executes, if any.
# Covers `bash deploy.sh`, `sh -e deploy.sh`, `source ./env.sh` and `./deploy.sh`.
# `bash -c "…"` is not a file and simply fails the existence test below; that
# form is already covered by guard_embedded_invocation.
guard_script_path() {
  local n i=0 t
  guard_tokenize "$1"
  n=${#GUARD_TOKENS[@]}
  [ $n -gt 0 ] || return 1
  while [ $i -lt $n ]; do
    case "${GUARD_TOKENS[$i]}" in
      [A-Za-z_]*=*)                       i=$((i + 1)); continue ;;
      sudo|env|nohup|time|exec|stdbuf|doas) i=$((i + 1)); continue ;;
    esac
    break
  done
  [ $i -lt $n ] || return 1
  t="${GUARD_TOKENS[$i]}"
  case "${t##*/}" in
    bash|sh|zsh|ksh|dash|source|.)
      i=$((i + 1))
      while [ $i -lt $n ]; do
        case "${GUARD_TOKENS[$i]}" in
          -*) i=$((i + 1)); continue ;;
          *)  printf '%s' "${GUARD_TOKENS[$i]}"; return 0 ;;
        esac
      done
      return 1 ;;
    *)
      # A path, not a PATH lookup — `./deploy.sh`, `/tmp/deploy.sh`.
      case "$t" in ./*|../*|/*) printf '%s' "$t"; return 0 ;; esac
      return 1 ;;
  esac
}

# guard_script_bodies <segments> — the segments of every script the command
# runs, so a destructive command is caught when it is *executed* from a file
# just as it is when typed inline. Writing the script stays free; running it
# does not.
#
# One level deep and bounded (4 scripts, 64 KiB each): a guard that recursed
# through an unbounded include graph on every Bash call would cost more than it
# is worth, and the wrapper safety net still covers what it misses.
guard_script_bodies() {
  local seg file n=0
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    file=$(guard_script_path "$seg") || continue
    [ -n "$file" ] || continue
    case "$file" in "~/"*) file="$HOME/${file#\~/}" ;; esac
    [ -f "$file" ] && [ -r "$file" ] || continue
    n=$((n + 1))
    [ $n -gt 4 ] && break
    guard_segments "$(guard_strip_heredocs "$(head -c 65536 "$file" 2>/dev/null)")"
  done <<EOF
$1
EOF
}

# guard_make_recipes <segments> — the segments of the recipe behind every
# `make <target>` the command runs.
#
# Same principle as guard_script_bodies: a Makefile target is a file full of
# commands, and running it is running them. Without this, `make deploy` is
# opaque and the only options are prompting on the name — which says nothing
# about what the target does — or missing a production `helm upgrade` entirely.
# With it, `make test` that tears down a namespace is caught and `make deploy`
# that only rsyncs is not.
#
# Bounded to 4 targets, one level deep, and no variable expansion: a recipe of
# `$(KUBECTL) delete …` is not classified, which is what the `make` entries in
# settings.json `permissions.ask` remain the backstop for.
guard_make_recipes() {
  local seg file target n=0 i tn found
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # Cheap pre-filter first: tokenizing every segment of every command to look
    # for a word that is almost never there is not worth the cycles.
    case "$seg" in *make*) ;; *) continue ;; esac

    guard_tokenize "$seg"
    tn=${#GUARD_TOKENS[@]}
    i=0
    while [ $i -lt $tn ]; do
      case "${GUARD_TOKENS[$i]}" in
        [A-Za-z_]*=*)                        i=$((i + 1)); continue ;;
        sudo|env|nohup|time|exec|stdbuf|doas) i=$((i + 1)); continue ;;
      esac
      break
    done
    [ $i -lt $tn ] || continue
    [ "${GUARD_TOKENS[$i]##*/}" = 'make' ] || continue

    # -f/--file/--makefile wins; otherwise the names make itself looks for.
    file=''
    found=$i
    i=$((i + 1))
    while [ $i -lt $tn ]; do
      case "${GUARD_TOKENS[$i]}" in
        -f|--file|--makefile)
          file="${GUARD_TOKENS[$((i + 1))]-}"; i=$((i + 2)); continue ;;
        --file=*|--makefile=*) file="${GUARD_TOKENS[$i]#*=}"; i=$((i + 1)); continue ;;
      esac
      i=$((i + 1))
    done
    if [ -z "$file" ]; then
      for target in GNUmakefile makefile Makefile; do
        [ -f "$target" ] && file="$target"
      done
    fi
    [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || continue

    # Everything after `make` that is not a flag, a flag value or a command-line
    # variable assignment is a goal.
    i=$((found + 1))
    while [ $i -lt $tn ]; do
      target="${GUARD_TOKENS[$i]}"
      case "$target" in
        -f|--file|--makefile) i=$((i + 2)); continue ;;
        -*|*=*)               i=$((i + 1)); continue ;;
      esac
      i=$((i + 1))
      n=$((n + 1))
      [ $n -gt 4 ] && break 2
      guard_segments "$(guard_make_recipe_of "$file" "$target")"
    done
  done <<EOF
$1
EOF
}

# guard_make_recipe_of <makefile> <target> — the recipe lines of one target.
# Recipe lines are the tab-indented block after `target:`; `@`, `-` and `+`
# prefixes are stripped because they change how make reports the command, not
# what runs. A `VAR := value` line is not a target, hence the `=` check.
guard_make_recipe_of() {
  awk -v t="$2" '
    !inrecipe {
      p = index($0, ":")
      if (p > 1) {
        head = substr($0, 1, p - 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", head)
        if (head == t && substr($0, p + 1, 1) != "=") inrecipe = 1
      }
      next
    }
    substr($0, 1, 1) == "\t" {
      line = substr($0, 2)
      sub(/^[@+-]+/, "", line)
      print line
      next
    }
    NF { inrecipe = 0 }
  ' "$1" 2>/dev/null
}

# GUARD_TOKENS[] = the segment's words, surrounding quotes stripped.
#
# Quote stripping is pure parameter substitution on purpose. Forking
# `printf | tr` per token made this the single most expensive thing the guards
# did — it runs for every segment of every command, times every profile.
guard_tokenize() {
  local seg="$1" t
  local raw
  GUARD_TOKENS=()
  for raw in $seg; do
    t="${raw//\"/}"
    t="${t//\'/}"
    [ -n "$t" ] && GUARD_TOKENS[${#GUARD_TOKENS[@]}]="$t"
  done
}

# guard_invocation <binary> <segment>
# 0 if the segment's command word is <binary>, after skipping leading env
# assignments (FOO=bar) and transparent wrappers (sudo/env/xargs/...).
# On success GUARD_ARGS[] holds everything after the binary.
guard_invocation() {
  local bin="$1" seg="$2" t i=0 n
  guard_tokenize "$seg"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    t="${GUARD_TOKENS[$i]}"
    case "$t" in
      -*) break ;;
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;                # FOO=bar prefix
      sudo|env|nohup|time|exec|stdbuf|xargs|doas)
        # Transparent only when followed by a plain word: `command -v helm`
        # and `xargs -n1 kubectl` keep their own command word.
        if [ $((i + 1)) -lt $n ]; then
          case "${GUARD_TOKENS[$((i + 1))]}" in
            -*) break ;;
            *) i=$((i + 1)); continue ;;
          esac
        fi
        break ;;
    esac
    break
  done
  [ $i -lt $n ] || return 1
  t="${GUARD_TOKENS[$i]}"
  [ "${t##*/}" = "$bin" ] || return 1
  GUARD_ARGS=()
  i=$((i + 1))
  while [ $i -lt $n ]; do
    GUARD_ARGS[${#GUARD_ARGS[@]}]="${GUARD_TOKENS[$i]}"
    i=$((i + 1))
  done
  return 0
}

# guard_subcommand <vocab-alternation> <value-flag-alternation>
# First GUARD_ARGS token that exactly matches the tool's known subcommand
# vocabulary, skipping the values of value-taking flags. Sets GUARD_SUB /
# GUARD_SUB_IDX. Exact matching is what keeps `values-template.yaml` from
# reading as `template` and `my-app-set` from reading as `set`.
guard_subcommand() {
  local vocab="$1" valflags="$2" i=0 n t prev=""
  GUARD_SUB=""; GUARD_SUB_IDX=-1
  n=${#GUARD_ARGS[@]}
  while [ $i -lt $n ]; do
    t="${GUARD_ARGS[$i]}"
    case "$t" in
      -*) prev="$t"; i=$((i + 1)); continue ;;
    esac
    if [ -n "$prev" ] && [[ "$prev" =~ ^($valflags)$ ]]; then
      prev=""; i=$((i + 1)); continue                        # flag value
    fi
    prev=""
    if [[ "$t" =~ ^($vocab)$ ]]; then
      GUARD_SUB="$t"; GUARD_SUB_IDX=$i; return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# guard_positionals [boolean-flag-alternation]
# GUARD_POS[] = positional args, using a generic heuristic for tools with an
# open-ended flag set (openstack, argocd): `--flag value` / `-f value` consume
# the next word unless it is itself a flag or the flag is a known boolean.
# Safe for those tools because their verb precedes the flags.
guard_positionals() {
  local bools="${1:-}" i=0 n t
  GUARD_POS=()
  n=${#GUARD_ARGS[@]}
  while [ $i -lt $n ]; do
    t="${GUARD_ARGS[$i]}"
    case "$t" in
      -*)
        if [ -n "$bools" ] && [[ "$t" =~ ^($bools)$ ]]; then
          i=$((i + 1)); continue
        fi
        case "$t" in *=*) i=$((i + 1)); continue ;; esac
        if [ $((i + 1)) -lt $n ]; then
          case "${GUARD_ARGS[$((i + 1))]}" in
            -*) ;;
            *) i=$((i + 2)); continue ;;
          esac
        fi
        i=$((i + 1)); continue ;;
    esac
    GUARD_POS[${#GUARD_POS[@]}]="$t"
    i=$((i + 1))
  done
}

# guard_pos_match <alternation> — print the first GUARD_POS entry matching it.
guard_pos_match() {
  local re="$1" p
  for p in ${GUARD_POS[@]+"${GUARD_POS[@]}"}; do
    if [[ "$p" =~ ^($re)$ ]]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# guard_arg_at <n> — Nth positional after the subcommand (1-based), "" if none.
# Uses the same value-flag skipping as guard_subcommand.
guard_arg_at() {
  local want="$1" valflags="${2:-}" i seen=0 n t prev=""
  n=${#GUARD_ARGS[@]}
  i=$((GUARD_SUB_IDX + 1))
  while [ $i -lt $n ]; do
    t="${GUARD_ARGS[$i]}"
    case "$t" in
      -*) prev="$t"; i=$((i + 1)); continue ;;
    esac
    if [ -n "$prev" ] && [ -n "$valflags" ] && [[ "$prev" =~ ^($valflags)$ ]]; then
      prev=""; i=$((i + 1)); continue
    fi
    prev=""
    seen=$((seen + 1))
    if [ "$seen" -eq "$want" ]; then printf '%s' "$t"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# guard_has_token <alternation> — 0 if any GUARD_ARGS token matches exactly.
guard_has_token() {
  local re="$1" t
  for t in ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}; do
    [[ "$t" =~ ^($re)$ ]] && return 0
  done
  return 1
}

# guard_has_flag <alternation> — like guard_has_token, but a flag written in
# assignment form counts as the flag: `date --set=2026-01-01` is `--set`, and
# a guard that only matched the bare token would read it as a clock read.
guard_has_flag() {
  local re="$1" t
  for t in ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}; do
    [[ "${t%%=*}" =~ ^($re)$ ]] && return 0
  done
  return 1
}

# guard_dry_run <alternation> — 0 when this invocation carries a dry-run flag
# that cannot persist anything. Scoped to GUARD_ARGS, i.e. to the segment being
# classified: in `argocd app sync app --dry-run && argocd app sync app` only the
# first invocation is a dry run, and a whole-command grep would wave both past.
# Stops at `--` for the same reason guard_is_help does.
guard_dry_run() {
  local re="$1" t
  for t in ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}; do
    [ "$t" = "--" ] && return 1
    [[ "$t" =~ ^($re)$ ]] && return 0
  done
  return 1
}

# guard_is_help — 0 when the invocation is a help/version request. Flags only:
# bare `help`/`version` would also match a resource literally named that.
# Scanning stops at `--`: everything after it belongs to the *inner* command
# (`kubectl exec pod -- sh --version` runs a shell, it does not print help).
#
# `--version` counts only as the *first* argument. Every tool guarded here also
# uses it as a value-taking flag further along, where it selects what to ship
# rather than asking for the CLI version: `helm --kube-context production
# upgrade app chart --version 1.2.3` is a production upgrade, not a help
# request, and treating it as one skipped classification entirely.
guard_is_help() {
  local t i=0
  for t in ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}; do
    [ "$t" = "--" ] && return 1
    case "$t" in
      --help|-h|-help) return 0 ;;
      --version) [ $i -eq 0 ] && return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# --- wrapper / eval safety net ----------------------------------------------

# guard_embedded_invocation <binary> <segment>
# For segments where the binary is not the command word but appears later:
# `timeout 300 kubectl …`, `nice -n 10 helm …`, `xargs -I{} kubectl …`,
# `sh -c "kubectl …"`, `eval "…"`, `for ns in …; do kubectl … ; done`,
# `docker run … bitnami/kubectl …`.
#
# GUARD_ARGS is set from the binary token onwards so the caller can run the
# *same* precise classifier it uses for a direct invocation — a wrapper must
# not turn a read-only command into a prompt, nor a mutation into a pass.
#
# Segments headed by a command that only prints or searches text are skipped:
# `echo "kubectl delete …"` is documentation, not an invocation.
guard_embedded_invocation() {
  local bin="$1" seg="$2" head t i n
  guard_tokenize "$seg"
  n=${#GUARD_TOKENS[@]}
  [ $n -gt 0 ] || return 1
  head="${GUARD_TOKENS[0]##*/}"
  case "$head" in
    echo|printf|cat|grep|egrep|fgrep|rg|ag|command|which|type|whereis|man|sed|awk|\
    head|tail|less|more|jq|yq|ls|find|history|comm|diff|wc|sort|uniq|tee|column|\
    \#*) return 1 ;;
  esac
  i=0
  while [ $i -lt $n ]; do
    # Match `helm`, `/usr/bin/helm`, `bitnami/helm` and `cmd=helm` alike: a
    # wrapper that takes the command as a variable still runs the command.
    t="${GUARD_TOKENS[$i]##*/}"
    if [ "${t##*=}" = "$bin" ]; then
      GUARD_HEAD="$head"
      GUARD_ARGS=()
      i=$((i + 1))
      while [ $i -lt $n ]; do
        GUARD_ARGS[${#GUARD_ARGS[@]}]="${GUARD_TOKENS[$i]}"
        i=$((i + 1))
      done
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# guard_reaches <binary> <segment> — the segment invokes the binary, directly
# or through a wrapper. Sets GUARD_ARGS either way.
guard_reaches() {
  GUARD_HEAD=""
  guard_invocation "$1" "$2" || guard_embedded_invocation "$1" "$2"
}

# guard_is_remote_wrapper — 0 when the binary was reached through something that
# runs it on another machine or in another container.
guard_is_remote_wrapper() {
  [ -n "$GUARD_HEAD" ] || return 1
  [[ "$GUARD_HEAD" =~ ^($GUARD_REMOTE_HEADS)$ ]]
}

# guard_flag_value <flag-alternation> — value of a flag given on the
# current segment (`-R owner/repo`, `--hostname=example.com`), or nothing.
guard_flag_value() {
  printf '%s' "$GUARD_SEG" \
    | grep -oE -- "(^|[[:space:]])($1)[= ][^[:space:]]+" \
    | head -n1 \
    | sed -E "s/.*($1)[= ]//" \
    | tr -d '"'"'"''
}

# guard_env_value <var-name> — value of `VAR=…` prefixed onto the current
# segment, or nothing. An inherited value is the caller's job to fall back to.
guard_env_value() {
  printf '%s' "$GUARD_SEG" \
    | grep -oE "(^|[;&|[:space:]])$1=[^[:space:]]+" \
    | head -n1 \
    | sed -E "s/.*$1=//" \
    | tr -d '"'"'"''
}
