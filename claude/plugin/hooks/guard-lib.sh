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

GUARD_JQ="${GUARD_JQ:-$(command -v jq || echo /usr/bin/jq)}"

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

# Read the hook JSON on stdin, print the working directory on the first line
# and the command on every line after it.
#
# One jq call for both — stdin can only be consumed once, and forking jq twice
# on every Bash tool call to read two fields is not worth it. The cwd goes
# first because the command is the field that can span lines; a caller that
# gets no newline back got no command and should stop.
guard_input() {
  "$GUARD_JQ" -r '(.cwd // "") + "\n" + (.tool_input.command // "")' 2>/dev/null
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

# --- per-project allowlist ---------------------------------------------------

# Pre-approved (project, binary, target, action) combinations, one rule per
# line, `|`-separated, `#` comments and blank lines ignored:
#
#   <project dir> | <binary> | <target glob> | <action glob>
#   ~/work/acme-api | mysql | host bench-db.internal* | *
#
# A rule says "inside this checkout, this tool against this target may do this
# without asking" — the benchmark database you re-seed twenty times an hour,
# the kind cluster, the sandbox workspace. The target is matched against the
# *resolved* target string, i.e. the exact text the prompt would have shown, so
# what you allow is what you would have read and approved anyway. Everything
# else in the same project still asks: a rule for bench-db.internal does
# nothing for a mistyped prod-db.internal.
#
# The file lives in $HOME and nowhere else on purpose. A guard an agent can
# switch off is not a guard, and an agent edits files inside the project all
# day — an allowlist checked into the repo (or written to it mid-session)
# would be self-approval with extra steps. It is read as data, never sourced,
# and ignored unless it belongs to the user running the hook.
#
# Read only when a prompt is about to fire, so the common path never touches
# the disk for it.
GUARD_ALLOW_FILE="${GUARD_ALLOW_FILE:-$HOME/.claude/guard-allow.conf}"

# guard_allowed <binary> <action> <target> — 0 when a rule covers this
# invocation in the current working directory ($GUARD_CWD).
guard_allowed() {
  local bin="$1" action="$2" target="$3" p b t a rc=1 was_set=0
  [ -f "$GUARD_ALLOW_FILE" ] && [ -r "$GUARD_ALLOW_FILE" ] || return 1
  [ -O "$GUARD_ALLOW_FILE" ] || return 1
  # Hostnames and SQL verbs are both case-insensitive, and the action string
  # echoes back whatever case the command was written in ("SQL TRUNCATE" for
  # one agent, "SQL truncate" for the next) — a rule that only matched one of
  # them would look like it worked until the day it silently did not.
  shopt -q nocasematch && was_set=1
  shopt -s nocasematch
  # `|| [ -n "$p" ]` so a final line without a trailing newline still counts.
  while IFS='|' read -r p b t a || [ -n "$p" ]; do
    p="$(guard_trim "$p")"
    case "$p" in ''|'#'*) continue ;; esac
    b="$(guard_trim "${b:-}")"
    t="$(guard_trim "${t:-}")"
    a="$(guard_trim "${a:-}")"
    [ -n "$b" ] || continue
    [ -n "$t" ] || t='*'
    [ -n "$a" ] || a='*'
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
    p="${p%/}"
    # The rule covers the project directory and everything under it, and is a
    # glob like the other fields, so `~/work/*-bench` and a bare `*` (every
    # project on this machine — think twice) both work.
    case "$GUARD_CWD/" in $p/*) ;; *) continue ;; esac
    [ "$b" = '*' ] || [ "$b" = "$bin" ] || continue
    # Unquoted on purpose: these are globs, and the right-hand side of [[ == ]]
    # is not word-split, so a target glob may contain spaces ("host bench-db*").
    [[ "$target" == $t ]] || continue
    [[ "$action" == $a ]] || continue
    rc=0
    break
  done < "$GUARD_ALLOW_FILE"
  [ "$was_set" = 1 ] || shopt -u nocasematch
  return $rc
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

# Interpreter APIs that hand a string to a shell or exec a program. Deliberately
# NOT including backticks or $( ) — those are handled precisely by
# guard_heredoc_expansions, and inside a *quoted* heredoc the shell never
# evaluates them anyway.
GUARD_EXEC_HINTS='os\.system|os\.popen|os\.exec|os\.spawn|subprocess|pty\.spawn|commands\.getoutput|shell_exec|proc_open|passthru|popen\(|system\(|exec\(|qx[({/|]|%x[({]|Open3|IO\.popen|Kernel#?\.?(system|spawn)|child_process|execSync|spawnSync|execFileSync|(sh|bash|zsh|ash|dash)[[:space:]]+-c'

# Who consumes a heredoc decides what the body *is*.
#
# A shell (or ssh, which is a shell on another machine) executes every line of
# it: the body is a script, and is classified as one. A non-shell interpreter
# executes it as code in another language, where the only thing we can spot is
# a call into an exec API. Everything else — `git commit -F -`, `cat > file`,
# `tee`, `jq`, `kubectl apply -f -` — is being handed data, and data that
# happens to contain the word `kubectl` is not an invocation.
GUARD_HEREDOC_SHELL_HEADS='sh|bash|zsh|ksh|dash|ash|ssh'
GUARD_HEREDOC_INTERP_HEADS='python|python2|python3|ruby|perl|node|php|lua|deno|bun|Rscript|osascript'
# Container runtimes are transport, not the consumer: `docker exec -i box bash
# <<EOF` runs the body in a shell. The shell word appears later on the line.
GUARD_HEREDOC_TRANSPORTS='docker|podman|nerdctl|lima|colima|kubectl'
# Every word that could make a heredoc body executable, as one word-bounded
# regex. A consumer that never appears anywhere in the command cannot appear on
# a heredoc's opening line either, so this is a sound necessary condition — and
# it is what keeps `cat > notes.md <<'EOF' … EOF`, far and away the most common
# heredoc there is, from walking its own body twice to learn that `cat` runs
# nothing. Word boundaries matter: a plain `*sh*` glob matches "should".
GUARD_HEREDOC_EXEC_RE='(^|[^A-Za-z0-9_./-])(sh|bash|zsh|ksh|dash|ash|ssh|python|python2|python3|ruby|perl|node|php|lua|deno|bun|Rscript|osascript|docker|podman|nerdctl|lima|colima|kubectl)([^A-Za-z0-9_-]|$)'

# guard_head_word <segment> — basename of the segment's command word, after env
# assignments and transparent wrappers, into $GUARD_HEAD_WORD. Non-zero when the
# segment has none.
#
# Sets a global rather than printing: every caller runs it per segment or per
# pipe stage, and `x=$(guard_head_word …)` is a fork each time — worth ~9ms on a
# command with a few segments, which is most of them.
GUARD_HEAD_WORD=''
guard_head_word() {
  local i=0 n
  GUARD_HEAD_WORD=''
  guard_tokenize "$1"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    case "${GUARD_TOKENS[$i]}" in
      [A-Za-z_]*=*)                        i=$((i + 1)); continue ;;
      sudo|env|nohup|time|exec|stdbuf|doas) i=$((i + 1)); continue ;;
    esac
    break
  done
  [ $i -lt $n ] || return 1
  GUARD_HEAD_WORD="${GUARD_TOKENS[$i]##*/}"
  return 0
}

# guard_heredoc_is_shell <consumer> <opening-line> — 0 when the body will be
# executed line by line as a shell script.
guard_heredoc_is_shell() {
  local consumer="$1" line="$2" t
  [[ "$consumer" =~ ^($GUARD_HEREDOC_SHELL_HEADS)$ ]] && return 0
  [[ "$consumer" =~ ^($GUARD_HEREDOC_TRANSPORTS)$ ]] || return 1
  guard_tokenize "$line"
  for t in ${GUARD_TOKENS[@]+"${GUARD_TOKENS[@]}"}; do
    case "${t##*/}" in
      sh|bash|zsh|ksh|dash|ash) return 0 ;;
    esac
  done
  return 1
}

# guard_heredoc_bodies <command> [all|unquoted|shell|interp]
# Prints heredoc bodies, one line each:
#
#   all       every body (what a caller wanting raw text asks for)
#   unquoted  only bodies whose delimiter was unquoted (`<<EOF`, not `<<'EOF'`),
#             i.e. the ones the shell still expands
#   shell     only bodies a shell or ssh executes
#   interp    only bodies another language's interpreter executes
#
# The two execution modes prefix each body with a `#guard-src:` provenance
# marker naming the consumer, so a prompt can say where the command came from.
# Markers are inert: guard_embedded_invocation already skips a `#`-headed
# segment and guard_invocation cannot match one.
#
# The walk mirrors guard_strip_heredocs; it runs only under the same `<<` glob,
# so the common command pays nothing for it.
guard_heredoc_bodies() {
  local want="${2:-all}"
  local line delim='' dashed=0 quoted=0 trimmed spec body emit=0 consumer=''
  while IFS= read -r line; do
    if [ -n "$delim" ]; then
      trimmed="$line"
      if [ "$dashed" = 1 ]; then
        while [ "${trimmed#	}" != "$trimmed" ]; do trimmed="${trimmed#	}"; done
      fi
      [ "$trimmed" = "$delim" ] && { delim=''; continue; }
      [ "$emit" = 1 ] && printf '%s\n' "$line"
      continue
    fi
    case "$line" in
      *'<<'*)
        spec=$(printf '%s' "$line" | sed -nE 's/.*<<(-?)[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"'|\\[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*).*/\1 \2/p')
        [ -n "$spec" ] || continue
        case "$spec" in
          -*) dashed=1 ;;
          *)  dashed=0 ;;
        esac
        body="${spec#* }"
        case "$body" in
          \"*|\'*|\\*) quoted=1 ;;
          *)           quoted=0 ;;
        esac
        # Strip whichever wrapper marked it quoted.
        body="${body#[\"\'\\]}"; body="${body%[\"\']}"
        delim="$body"
        emit=0
        case "$want" in
          all)      emit=1 ;;
          unquoted) [ "$quoted" = 0 ] && emit=1 ;;
          shell|interp)
            guard_head_word "$line" || GUARD_HEAD_WORD=''
            consumer="$GUARD_HEAD_WORD"
            if [ -n "$consumer" ]; then
              if [ "$want" = shell ]; then
                guard_heredoc_is_shell "$consumer" "$line" && emit=1
              elif [[ "$consumer" =~ ^($GUARD_HEREDOC_INTERP_HEADS)$ ]]; then
                emit=1
              fi
            fi
            [ "$emit" = 1 ] && printf '#guard-src:heredoc into %s\n' "$consumer" ;;
        esac ;;
    esac
  done <<EOF
$1
EOF
  return 0
}

# guard_heredoc_script_bodies <command> — the segments of every heredoc body a
# shell or ssh executes.
#
# `bash <<'EOF' … kubectl --context production delete pod api … EOF` is not a
# document, it is a script arriving on stdin, and stripping the body as data
# made it — and the `ssh host <<'EOF'` form, which runs on another machine
# entirely — completely silent. Classified like a script file, so the prompt
# names the real target rather than throwing up its hands at an opaque body.
guard_heredoc_script_bodies() {
  guard_segments "$(guard_strip_heredocs "$(guard_heredoc_bodies "$1" shell)")"
}

# guard_heredoc_expansions <command> — the command substitutions the shell would
# actually run while writing an unquoted heredoc, one per line.
#
# `cat > runbook.md <<EOF … kubectl delete … EOF` is documentation and must stay
# silent (guard_strip_heredocs drops the whole body for exactly that reason).
# But an *unquoted* delimiter still expands, so
#   python3 - <<EOF
#   x = "$(kubectl --context production delete pod api)"
#   EOF
# runs the delete before python3 ever sees a byte. Pulling just the substitution
# out gives the classifier a real invocation with a resolvable target, instead of
# either missing it or prompting on prose.
guard_heredoc_expansions() {
  guard_heredoc_bodies "$1" unquoted \
    | grep -oE '\$\([^()]*\)|`[^`]*`' 2>/dev/null \
    | sed -e 's/^\$(//' -e 's/^`//' -e 's/)$//' -e 's/`$//'
}

# guard_heredoc_shells_out <binary>
# 0 when a heredoc body both mentions <binary> and calls an interpreter API that
# can run it — `python3 - <<'PY' … subprocess.run(['kubectl','delete',…]) … PY`.
# The body is opaque: we cannot tell which target it would hit, or whether the
# mention is even the one executed, so the caller asks rather than guessing.
# Writing chart YAML or a pipeline file trips neither half and stays silent.
guard_heredoc_shells_out() {
  local bin="$1"
  [ -n "${GUARD_HEREDOC_BODY:-}" ] || return 1
  printf '%s' "$GUARD_HEREDOC_BODY" | grep -qE "$GUARD_EXEC_HINTS" || return 1
  printf '%s' "$GUARD_HEREDOC_BODY" \
    | grep -qE "(^|[^A-Za-z0-9_./-])$bin([^A-Za-z0-9_-]|\$)" || return 1
  return 0
}

# --- executed scripts -------------------------------------------------------

# guard_script_path <segment> [nofs] — the script file this segment executes,
# into $GUARD_SCRIPT_PATH. Covers `bash deploy.sh`, `sh -e deploy.sh`,
# `source ./env.sh` and `./deploy.sh`. `bash -c "…"` is not a file and simply
# fails the existence test in the caller; that form is already covered by
# guard_embedded_invocation.
#
# Sets a global rather than printing, for the same reason guard_head_word does:
# both callers run it once per segment, and a command substitution there is a
# fork per segment of every command.
GUARD_SCRIPT_PATH=''
guard_script_path() {
  local n i=0 t nofs="${2:-}"
  GUARD_SCRIPT_PATH=''
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
          *)  GUARD_SCRIPT_PATH="${GUARD_TOKENS[$i]}"; return 0 ;;
        esac
      done
      return 1 ;;
    *)
      # A path, not a PATH lookup — `./deploy.sh`, `/tmp/deploy.sh`.
      #
      # The executable bit is required here and not for the interpreter form
      # above, where the head word already said "run this". guard_segments
      # splits on `(`, `)` and `|`, so a *data* path lands in head position all
      # the time — `json.load(open('/tmp/data.json'))` and `>| /tmp/out.json`
      # both produce a segment that is nothing but the path. Reading those and
      # classifying their contents prompted on text inside a JSON file.
      #
      # With "nofs" the bit is not consulted, for the one caller that must not:
      # guard_inline_scripts matches against a file this command is about to
      # *create*, which by definition is neither present nor executable yet.
      case "$t" in
        ./*|../*|/*)
          [ "$nofs" = nofs ] || [ -x "$t" ] || return 1
          GUARD_SCRIPT_PATH="$t"; return 0 ;;
      esac
      return 1 ;;
  esac
}

# guard_redirect_target <segment> — the file the segment redirects stdout into
# (`> f`, `>> f`, `>| f`, `1> f`, and the unspaced forms), or nothing.
guard_redirect_target() {
  local i=0 n t
  guard_tokenize "$1"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    t="${GUARD_TOKENS[$i]}"
    case "$t" in
      '>'|'>>'|'>|'|'1>'|'1>>'|'1>|')
        i=$((i + 1))
        [ $i -lt $n ] || return 1
        printf '%s' "${GUARD_TOKENS[$i]}"; return 0 ;;
      '>'*|'1>'*)
        t="${t#1}"; t="${t#>}"; t="${t#>}"; t="${t#|}"
        [ -n "$t" ] && { printf '%s' "$t"; return 0; } ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# guard_tee_target <segment> — tee's first file operand (`tee deploy.sh`).
guard_tee_target() {
  local i=0 n t
  guard_tokenize "$1"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    [ "${GUARD_TOKENS[$i]##*/}" = tee ] && { i=$((i + 1)); break; }
    i=$((i + 1))
  done
  while [ $i -lt $n ]; do
    t="${GUARD_TOKENS[$i]}"
    i=$((i + 1))
    case "$t" in -*|'<<'*) continue ;; esac
    printf '%s' "$t"; return 0
  done
  return 1
}

# guard_is_text <file> — 0 when the first 1 KiB is printable text.
#
# `/usr/bin/python3 - <<'PY'` puts an executable *binary* in head position, and
# `head -c 65536` on a Mach-O image yields garbage segments plus `tr: Illegal
# byte sequence` on stderr. LC_ALL=C is what makes tr byte-oriented rather than
# choking on invalid UTF-8; `wc -c` rather than testing `$(…)` for emptiness
# because command substitution silently drops NUL bytes, which is most of what
# distinguishes a binary in the first place.
guard_is_text() {
  local n
  n=$(LC_ALL=C head -c 1024 "$1" 2>/dev/null | LC_ALL=C tr -d '[:print:][:space:]' | wc -c)
  [ "${n:-1}" -eq 0 ]
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
    guard_script_path "$seg" || continue
    file="$GUARD_SCRIPT_PATH"
    [ -n "$file" ] || continue
    case "$file" in "~/"*) file="$HOME/${file#\~/}" ;; esac
    [ -f "$file" ] && [ -r "$file" ] || continue
    guard_is_text "$file" || continue
    n=$((n + 1))
    [ $n -gt 4 ] && break
    printf '#guard-src:script %s\n' "${file##*/}"
    guard_segments "$(guard_strip_heredocs "$(head -c 65536 "$file" 2>/dev/null)")"
  done <<EOF
$1
EOF
}

# --- a script written and run in the same command ----------------------------

# guard_inline_scripts <raw-command> <segments> — the segments of a script this
# very command writes and then executes.
#
# guard_script_bodies reads from disk, which is right for a script that already
# exists and useless for `cat > deploy.sh <<'EOF' … EOF && bash deploy.sh`: the
# hook runs *before* the command, so at classification time the file is absent
# or still holds its old contents. That made write-then-run in a single Bash
# call the one shape that could route around every guard. The body is in the
# command line, though, so it is matched to the execution by path instead of by
# reading the file.
#
# Narrow on purpose, because the ways to get this wrong are the ones that have
# already cost us. The body only *is* the file when a pass-through consumer
# writes it — `cat >`, `tee`, `echo >`, `printf >`. `python3 - <<'PY' >| out.json`
# also pairs a heredoc with a redirect, but there the body is python source and
# out.json is python's *output*; treating one as the other is exactly how a JSON
# blob came to be read as a shell script. And nothing is emitted unless the
# command also executes that path: writing a runbook stays free.
guard_inline_scripts() {
  local raw="$1" segs="$2"
  local seg path targets='|' found=0 n=0
  local line delim='' dashed=0 trimmed spec dl body='' consumer wrote='' emit=0

  # Cheap pre-filter: a command that writes no file cannot write a script.
  # `tee` earns its own arm because it takes the file as an operand — there is
  # no `>` anywhere in `tee deploy.sh <<'EOF'`.
  case "$raw" in *'>'*|*tee*) ;; *) return 0 ;; esac

  # What this command executes. The filesystem is deliberately not consulted —
  # the whole point is that the file is not there yet.
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    guard_script_path "$seg" nofs || continue
    path="$GUARD_SCRIPT_PATH"
    [ -n "$path" ] || continue
    targets="$targets${path#./}|"
    found=1
  done <<EOF
$segs
EOF
  [ $found -eq 1 ] || return 0

  # `echo "kubectl … delete …" > deploy.sh`, `printf … > deploy.sh`
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    case "$seg" in *'>'*) ;; *) continue ;; esac
    guard_head_word "$seg" || continue
    consumer="$GUARD_HEAD_WORD"
    case "$consumer" in echo|printf) ;; *) continue ;; esac
    wrote=$(guard_redirect_target "$seg") || continue
    wrote="${wrote#./}"
    case "$targets" in *"|$wrote|"*) ;; *) continue ;; esac
    n=$((n + 1))
    [ $n -gt 4 ] && break
    printf '#guard-src:script %s written in this command\n' "${wrote##*/}"
    guard_segments "$(guard_pipe_text "$seg" "$consumer")"
  done <<EOF
$segs
EOF

  # `cat > deploy.sh <<'EOF' … EOF`, `tee deploy.sh <<'EOF' … EOF`
  while IFS= read -r line; do
    if [ -n "$delim" ]; then
      trimmed="$line"
      if [ "$dashed" = 1 ]; then
        while [ "${trimmed#	}" != "$trimmed" ]; do trimmed="${trimmed#	}"; done
      fi
      if [ "$trimmed" = "$delim" ]; then
        delim=''
        if [ "$emit" = 1 ]; then
          printf '#guard-src:script %s written in this command\n' "${wrote##*/}"
          guard_segments "$body"
        fi
        emit=0; body=''
        continue
      fi
      [ "$emit" = 1 ] && body="$body$line
"
      continue
    fi
    case "$line" in
      *'<<'*)
        spec=$(printf '%s' "$line" | sed -nE 's/.*<<(-?)[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"'|\\[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*).*/\1 \2/p')
        [ -n "$spec" ] || continue
        case "$spec" in -*) dashed=1 ;; *) dashed=0 ;; esac
        dl="${spec#* }"
        dl="${dl#[\"\'\\]}"; dl="${dl%[\"\']}"
        delim="$dl"
        body=''; emit=0; wrote=''
        guard_head_word "$line" || GUARD_HEAD_WORD=''
        consumer="$GUARD_HEAD_WORD"
        case "$consumer" in
          cat) wrote=$(guard_redirect_target "$line") || wrote='' ;;
          tee) wrote=$(guard_tee_target "$line")      || wrote='' ;;
        esac
        if [ -n "$wrote" ]; then
          wrote="${wrote#./}"
          case "$targets" in
            *"|$wrote|"*)
              n=$((n + 1))
              [ $n -le 4 ] && emit=1 ;;
          esac
        fi ;;
    esac
  done <<EOF
$raw
EOF
  return 0
}

# --- a pipeline whose sink is a shell ----------------------------------------

# guard_shell_pipes <raw-command> — the segments of whatever a pipeline feeds
# into a shell, plus a `#guard-src:` marker naming where it came from.
#
# `cat deploy.sh | bash` is `bash deploy.sh` and `echo "kubectl … delete …" |
# sh` is that delete, but guard_segments splits on `|`, so by the time a profile
# sees them the producer and the shell are unrelated fragments and neither is an
# invocation of anything. The relationship survives only in $GUARD_RAW_CMD —
# the same problem _sql.sh already solves for `cat migrate.sql | mysql`.
#
# A producer whose text we can read is read. An opaque one (`curl … | bash`)
# gets a `#guard-opaque-pipe` line so the caller can ask: a script nobody has
# read is not a thing to discover afterwards. It is a marker rather than a
# variable because this runs in a command substitution, where an assignment
# would never reach the caller.
guard_shell_pipes() {
  local raw="$1" prod sink shead phead
  # Both conditions are necessary and cost nothing: no pipe, no pipeline, and
  # every shell this cares about — sh, bash, zsh, ksh, dash, ash — contains the
  # substring "sh", so a command without one has no shell sink. Worth the two
  # globs: `cat a.txt | sort | uniq -c` would otherwise fork awk and tokenize
  # every stage to discover there is nothing here.
  case "$raw" in *'|'*) ;; *) return 0 ;; esac
  case "$raw" in *sh*)  ;; *) return 0 ;; esac
  while IFS='	' read -r prod sink; do
    [ -n "$prod" ] && [ -n "$sink" ] || continue
    guard_head_word "$sink" || continue
    shead="$GUARD_HEAD_WORD"
    case "$shead" in sh|bash|zsh|ksh|dash|ash) ;; *) continue ;; esac
    # A shell given a script operand (or -c) is not reading stdin, and both of
    # those forms are already classified elsewhere.
    guard_sink_reads_stdin "$sink" || continue
    guard_head_word "$prod" || continue
    phead="$GUARD_HEAD_WORD"
    case "$phead" in
      cat|echo|printf)
        printf '#guard-src:pipe into %s\n' "$shead"
        guard_segments "$(guard_strip_heredocs "$(guard_pipe_text "$prod" "$phead")")" ;;
      *) printf '#guard-opaque-pipe %s %s\n' "$phead" "$shead" ;;
    esac
  done <<EOF
$(printf '%s\n' "$raw" | awk -F'|' '{
    prev = ""
    for (i = 1; i <= NF; i++) {
      # An empty field is the gap inside `||`, which is a conditional, not a
      # pipe — reset so `cat f.sh || bash` is not read as `cat f.sh | bash`.
      if ($i == "") { prev = ""; continue }
      if (prev != "") print prev "\t" $i
      prev = $i
    }
  }')
EOF
  return 0
}

# guard_sink_reads_stdin <segment> — 0 when this shell invocation takes its
# script from stdin rather than from a file operand or -c.
guard_sink_reads_stdin() {
  local i n t
  guard_tokenize "$1"
  n=${#GUARD_TOKENS[@]}
  i=0
  while [ $i -lt $n ]; do
    case "${GUARD_TOKENS[$i]}" in
      [A-Za-z_]*=*)                        i=$((i + 1)); continue ;;
      sudo|env|nohup|time|exec|stdbuf|doas) i=$((i + 1)); continue ;;
    esac
    break
  done
  i=$((i + 1))
  while [ $i -lt $n ]; do
    t="${GUARD_TOKENS[$i]}"
    case "$t" in
      -c) return 1 ;;
      -*) i=$((i + 1)); continue ;;
      *)  return 1 ;;
    esac
  done
  return 0
}

# guard_pipe_text <producer-segment> <producer-head> — the text the producer
# writes to the pipe: the contents of the files `cat` names, or the words
# `echo`/`printf` were given.
guard_pipe_text() {
  local prod="$1" phead="$2" i=0 n t out=''
  guard_tokenize "$prod"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    [ "${GUARD_TOKENS[$i]##*/}" = "$phead" ] && { i=$((i + 1)); break; }
    i=$((i + 1))
  done
  if [ "$phead" = cat ]; then
    while [ $i -lt $n ]; do
      t="${GUARD_TOKENS[$i]}"
      i=$((i + 1))
      case "$t" in -*) continue ;; esac                    # cat -n, cat -v
      case "$t" in "~/"*) t="$HOME/${t#\~/}" ;; esac
      [ -f "$t" ] && [ -r "$t" ] || continue
      guard_is_text "$t" || continue
      head -c 65536 "$t" 2>/dev/null
    done
    return 0
  fi
  # echo/printf: only the *leading* flags belong to the producer (`echo -n`,
  # `printf -v`). Everything from the first non-flag word on is the payload and
  # is kept verbatim — dropping flags there ate the `--context` out of
  # `echo "kubectl --context wonka-factory delete pod x" | sh`, and a prompt
  # that then falls back to the ambient context names the wrong cluster.
  while [ $i -lt $n ]; do
    case "${GUARD_TOKENS[$i]}" in -*) i=$((i + 1)); continue ;; esac
    break
  done
  while [ $i -lt $n ]; do
    out="$out ${GUARD_TOKENS[$i]}"
    i=$((i + 1))
  done
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
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
      printf '#guard-src:make target %s\n' "$target"
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
    # Backslashes go too. A nested quote is routinely written escaped —
    # `sh -c "kubectl --context prod \"delete\" pod x"` — and stripping only the
    # quote characters leaves `\kubectl` / `\delete`, which match neither the
    # binary nor any subcommand vocabulary, so the whole invocation slips past.
    # Parameter expansion, not `tr`: this runs per token of every segment of
    # every command, and a fork here costs ~8ms per call.
    t="${t//\\/}"
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
      sudo|env|nohup|time|exec|stdbuf|xargs|doas|command)
        # Transparent only when followed by a plain word: `command -v helm`
        # and `xargs -n1 kubectl` keep their own command word.
        #
        # `command` belongs here, not only in guard_embedded_invocation's skip
        # list: `command kubectl delete pod x` really does run kubectl, and
        # being treated as a lookup made it a free bypass. The `-*` break below
        # is what still keeps `command -v helm` quiet.
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
#
# The token set is $GUARD_HELP_TOKENS, not a hardcoded pattern: bare `-h` is
# help for every tool guarded here except mysql/psql, where `-h` is `--host`.
# A profile whose short help flag differs (or collides, as those two do)
# overrides GUARD_HELP_TOKENS; guard_profile_reset supplies the common default.
guard_is_help() {
  local t i=0
  for t in ${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}; do
    [ "$t" = "--" ] && return 1
    case "$t" in
      --version) [ $i -eq 0 ] && return 0 ;;
    esac
    [[ "$t" =~ ^($GUARD_HELP_TOKENS)$ ]] && return 0
    i=$((i + 1))
  done
  return 1
}

# --- misc string helpers -----------------------------------------------------

# guard_where — ` Command: \`<segment>\` (from <source>).` for the prompt.
#
# The reason used to name the binary, the verb and the target but never the
# command, which is the one thing a human can check at a glance. It matters most
# for a segment that is not in what was typed at all: a line out of a script
# body, a make recipe, a heredoc a shell is about to execute, or a pipe — hence
# $GUARD_SRC, set from the `#guard-src:` markers the expanders emit.
#
# Truncating *before* substituting is load-bearing, not cosmetic. Under
# /bin/bash 3.2 (the shebang this runs with) `${var//…}` is quadratic, and a
# segment can be a 9 KB `-e "…"` value — substituting first is a 44-second hang,
# which is what the "does not hang" test exists to catch.
guard_where() {
  local s="${GUARD_SEG:-}"
  [ -n "$s" ] || return 0
  s="${s:0:200}"
  s="${s//$'\n'/ }"
  s="$(guard_trim "$s")"
  [ ${#s} -gt 160 ] && s="${s:0:157}..."
  if [ -n "${GUARD_SRC:-}" ]; then
    printf ' Command: `%s` (from %s).' "$s" "$GUARD_SRC"
  else
    printf ' Command: `%s`.' "$s"
  fi
}

# guard_trim — leading/trailing whitespace stripped, pure parameter expansion
# (no fork), for comparing a segment against a raw command-line fragment.
guard_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# guard_heredoc_body_for <raw-command> <opening-line> — the body text of the
# heredoc opened by the first raw-command line containing <opening-line> as a
# substring, or nothing.
#
# Exists because env-guard.sh strips every heredoc body before any profile
# runs (see guard_strip_heredocs) — correct for tools whose payload is data
# (kubectl YAML, helm values), wrong for a tool whose payload IS the command
# (`mysql -h prod <<'SQL' … SQL` — the DROP is only in the body). A profile
# that needs the body reconstructs it from $GUARD_RAW_CMD, the pre-strip
# command env-guard.sh sets aside for exactly this.
#
# Substring match, not exact-line match, on purpose: <opening-line> is a
# post-segmentation fragment (`guard_segments` may have split its source line
# on `&&`/`;`), so it can be shorter than the raw line that contains it. First
# match wins — two byte-identical heredoc-opening invocations in one command
# is a corner case this does not chase.
guard_heredoc_body_for() {
  local cmd="$1" open="$2" line delim='' dashed=0 trimmed spec found=0 body=''
  open="$(guard_trim "$open")"
  [ -n "$open" ] || return 1
  while IFS= read -r line; do
    if [ -n "$delim" ]; then
      trimmed="$line"
      if [ "$dashed" = 1 ]; then
        while [ "${trimmed#	}" != "$trimmed" ]; do trimmed="${trimmed#	}"; done
      fi
      if [ "$trimmed" = "$delim" ]; then
        delim=''
        if [ "$found" = 1 ]; then printf '%s' "$body"; return 0; fi
        continue
      fi
      [ "$found" = 1 ] && body="${body}${line}
"
      continue
    fi
    case "$line" in
      *'<<'*)
        spec=$(printf '%s' "$line" | sed -nE 's/.*<<(-?)[[:space:]]*("([^"]+)"|'"'"'([^'"'"']+)'"'"'|([A-Za-z_][A-Za-z0-9_]*)).*/\1\3\4\5/p')
        case "$spec" in
          '') ;;
          -*) dashed=1; delim="${spec#-}" ;;
          *)  dashed=0; delim="$spec" ;;
        esac
        if [ -n "$delim" ] && [ "$found" = 0 ]; then
          case "$line" in *"$open"*) found=1 ;; esac
        fi
        ;;
    esac
  done <<EOF
$cmd
EOF
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
#
# `find`, `sed` and `awk` are deliberately NOT in that list — each can run a
# command built from its own arguments (`find … -exec`, GNU `sed '1e cmd'` and
# `s///e`, `awk '{system(…)}'`), so a segment headed by one of them still needs
# classifying. They cost nothing in false positives: a search pattern like
# `sed -n "/kubectl delete/p"` tokenizes to `delete/p`, which is not an exact
# match in any subcommand vocabulary. `fd` and `xargs` are likewise absent
# because `fd -x` and `xargs` exec by design.
guard_embedded_invocation() {
  local bin="$1" seg="$2" head t i n hi=0
  guard_tokenize "$seg"
  n=${#GUARD_TOKENS[@]}
  [ $n -gt 0 ] || return 1
  # The head is what the segment is *run by*, so leading env assignments and
  # transparent wrappers are skipped before reading it. Taking token 0 blindly
  # meant `DOCKER_HOST=tcp://prod:2375 docker exec … mysql -e "drop …"` reported
  # a head of `prod:2375` (`${t##*/}` of the assignment) and `FOO=bar ssh host …`
  # a head of `FOO=bar` — so guard_is_remote_wrapper saw neither as remote, the
  # mutation resolved against the *local* default, and it ran in silence. Any
  # env prefix at all was a bypass of every remote-wrapper check.
  while [ $hi -lt $n ]; do
    case "${GUARD_TOKENS[$hi]}" in
      [A-Za-z_]*=*)                        hi=$((hi + 1)); continue ;;
      sudo|env|nohup|time|exec|stdbuf|doas) hi=$((hi + 1)); continue ;;
    esac
    break
  done
  [ $hi -lt $n ] || return 1
  head="${GUARD_TOKENS[$hi]##*/}"
  case "$head" in
    echo|printf|cat|grep|egrep|fgrep|rg|ag|command|which|type|whereis|man|\
    head|tail|less|more|jq|yq|ls|history|comm|diff|wc|sort|uniq|tee|column|\
    \#*) return 1 ;;
    # `git grep` and `git log -S` search text like the tools above; every other
    # git subcommand is left to be classified, since `git` is not blanket-inert.
    git)
      if [ $((hi + 1)) -lt $n ]; then
        case "${GUARD_TOKENS[$((hi + 1))]}" in
          grep|log|show|blame|diff|config|ls-files) return 1 ;;
        esac
      fi ;;
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

# Container runtimes whose daemon may or may not be on this machine, so the
# endpoint has to be resolved rather than assumed either way.
GUARD_CONTAINER_HEADS='docker|podman|nerdctl'
# Local-VM managers with no remote mode at all: colima and lima provision a VM
# on this machine and nothing else, so `colima ssh -- …` is always local.
GUARD_LOCAL_VM_HEADS='colima|lima'
# Docker contexts that are a local runtime. colima and OrbStack create one
# context per profile (colima-gravity, php-8.1), hence the suffix patterns; an
# unrecognised name is not assumed local, it is looked up.
GUARD_DOCKER_LOCAL_CONTEXTS='^(default|desktop-linux|orbstack.*|colima.*|rancher-desktop|minikube|lima.*|podman.*)$'

# guard_docker_is_local — 0 when the container runtime this segment talks to
# runs on this machine.
#
# Only the runtime's *own* flags count, and they precede its subcommand: in
# `docker exec -i tools kubectl --context production …` the `--context` belongs
# to kubectl, and reading it as a docker context would resolve the wrong target
# entirely. Explicit endpoint wins, then an env prefix, then the selected
# context — the same precedence docker itself uses.
guard_docker_is_local() {
  local i=0 n t ep='' ctx='' dbin
  guard_tokenize "$GUARD_SEG"
  n=${#GUARD_TOKENS[@]}
  while [ $i -lt $n ]; do
    case "${GUARD_TOKENS[$i]}" in
      DOCKER_HOST=*)    ep="${GUARD_TOKENS[$i]#DOCKER_HOST=}";     i=$((i + 1)); continue ;;
      CONTAINER_HOST=*) ep="${GUARD_TOKENS[$i]#CONTAINER_HOST=}";  i=$((i + 1)); continue ;;
      DOCKER_CONTEXT=*) ctx="${GUARD_TOKENS[$i]#DOCKER_CONTEXT=}"; i=$((i + 1)); continue ;;
      [A-Za-z_]*=*)                        i=$((i + 1)); continue ;;
      sudo|env|nohup|time|exec|stdbuf|doas) i=$((i + 1)); continue ;;
    esac
    break
  done
  i=$((i + 1))                                   # past the runtime word itself
  while [ $i -lt $n ]; do
    t="${GUARD_TOKENS[$i]}"
    case "$t" in
      -H|--host)    ep="${GUARD_TOKENS[$((i + 1))]-}";  i=$((i + 2)); continue ;;
      --host=*)     ep="${t#--host=}";                  i=$((i + 1)); continue ;;
      -c|--context) ctx="${GUARD_TOKENS[$((i + 1))]-}"; i=$((i + 2)); continue ;;
      --context=*)  ctx="${t#--context=}";              i=$((i + 1)); continue ;;
      -*)           i=$((i + 1)); continue ;;
      *)            break ;;                     # the subcommand; the rest is not ours
    esac
  done
  [ -n "$ep" ]  || ep="${DOCKER_HOST:-}"
  [ -n "$ctx" ] || ctx="${DOCKER_CONTEXT:-}"
  # An endpoint is conclusive on its own: a unix socket or a file descriptor is
  # this machine, tcp:// and ssh:// are not.
  if [ -n "$ep" ]; then
    case "$ep" in unix://*|fd://*|/*) return 0 ;; *) return 1 ;; esac
  fi
  if [ -z "$ctx" ]; then
    [ "$GUARD_HEAD" = docker ] || return 0       # podman/nerdctl default to local
    dbin="$(command -v docker 2>/dev/null)" || return 1
    ctx=$("$dbin" context show 2>/dev/null) || ctx=''
    [ -n "$ctx" ] || return 1
  fi
  [[ "$ctx" =~ $GUARD_DOCKER_LOCAL_CONTEXTS ]] && return 0
  # An unfamiliar name may still be a local socket — ask docker rather than
  # guess from the name.
  dbin="$(command -v docker 2>/dev/null)" || return 1
  ep=$("$dbin" context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>/dev/null) || ep=''
  case "$ep" in unix://*|fd://*|/*) return 0 ;; *) return 1 ;; esac
}

# guard_is_remote_wrapper — 0 when the binary was reached through something that
# runs it on another machine or in another container.
#
# A container runtime is only "somewhere else" if its daemon is, and on a laptop
# it usually is not: colima, OrbStack and Docker Desktop all expose a unix
# socket here. Prompting on every `docker exec -i db mysql` against a throwaway
# dev container is the reflexive-approval failure mode rule 1 warns about, and
# the inner command still carries its own target and is still classified — so
# `docker exec -i tools kubectl --context production delete …` asks on the
# strength of *production*, which is the honest reason.
guard_is_remote_wrapper() {
  [ -n "$GUARD_HEAD" ] || return 1
  [[ "$GUARD_HEAD" =~ ^($GUARD_REMOTE_HEADS)$ ]] || return 1
  [[ "$GUARD_HEAD" =~ ^($GUARD_LOCAL_VM_HEADS)$ ]] && return 1
  if [[ "$GUARD_HEAD" =~ ^($GUARD_CONTAINER_HEADS)$ ]] && guard_docker_is_local; then
    return 1
  fi
  return 0
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
