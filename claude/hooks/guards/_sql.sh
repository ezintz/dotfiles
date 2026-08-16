# Shared SQL-classification helpers for the mysql and psql profiles. Not a
# profile itself (the dispatcher only globs *.guard), sourced by both.
#
# Neither tool has a subcommand argv the way kubectl/helm do — the verb lives
# inside SQL text, and that text reaches the client through one of five
# channels: an -e/-c flag value, a herestring, a heredoc body, a file (`-f` or
# `<`), or standard input from a pipe. Both profiles use GUARD_STYLE='sql' and
# do all of their classification in guard_classify_extra by finding whichever
# channel is in play and scanning it, rather than matching an argv position.
#
# guard_segments (guard-lib.sh) treats `;`/`&`/`|`/`(` as shell separators
# unconditionally, quoting blind — correct for real shell syntax, wrong for
# those same characters sitting inside a quoted -e/-c value: `mysql -e "select
# 1; drop table x;"` gets truncated to "select 1" before any profile ever sees
# it. guard_reconstruct_segment repairs this by reattaching what the segmenter
# cut off, read from $GUARD_RAW_CMD (the pre-split original env-guard.sh sets
# aside), and guard_sql_invocation_text then cuts that repaired text back down
# to *this* invocation, respecting quotes — without which the repair overshoots
# into the next command and reads its payload as this one's.
#
# Quoting discipline: quotes are stripped only where they delimit a payload
# this file deliberately extracted (a flag value, a herestring). They are never
# stripped blanket-fashion from a whole command line, because that turns a
# string literal into a verb — `-e "select … where state = 'delete'"` is a
# read, and a guard that prompts on it gets approved reflexively.

# Verbs that mutate data, schema or permissions in a way that cannot be
# trivially walked back. Deliberately excludes CREATE/INSERT/SELECT — the
# first two are reversible (drop/delete what you created), the third reads.
GUARD_SQL_DESTRUCTIVE='drop|truncate|delete|update|alter|rename|grant|revoke|replace|lock|kill|shutdown|merge'

# Commands that produce SQL text this file can read for itself. Anything else
# upstream of a pipe into the client is opaque — see guard_sql_pipe_classify.
GUARD_SQL_TRANSPARENT_PIPE='echo|printf|cat'

# guard_sql_destructive_word <text> — prints the first token in <text> that
# exactly matches a destructive SQL keyword (case-insensitive; SQL keywords
# are), or nothing. Tokens are whitespace-split with `;,()` trimmed, so "DROP
# TABLE x;" and multi-line heredoc/file text both scan correctly. Exact match
# only, same discipline as guard_has_token elsewhere in this repo: a column or
# table named "deleted_at" is one token and never equals the bare keyword, and
# a quoted literal 'update' keeps its quotes and so does not match either.
guard_sql_destructive_word() {
  local text="$1" raw w was_set=0
  shopt -q nocasematch && was_set=1
  shopt -s nocasematch
  for raw in $text; do
    # The length cap is not an optimisation, it is what keeps this from
    # hanging the tool call. bash 3.2 — the /bin/bash this hook runs under —
    # needs 44 *seconds* to apply a bracket-class substitution to a 9 KB word
    # (bash 5: 31ms), and `-e "delete from t where id in (1,2,…,2000)"` is one
    # such word. Nothing is lost: the match below is exact, so a token only
    # counts if it strips down to a keyword of eight characters or fewer.
    [ ${#raw} -le 64 ] || continue
    w="${raw//[;(),]/}"
    if [[ -n "$w" && "$w" =~ ^($GUARD_SQL_DESTRUCTIVE)$ ]]; then
      [ "$was_set" = 1 ] || shopt -u nocasematch
      printf '%s' "$w"
      return 0
    fi
  done
  [ "$was_set" = 1 ] || shopt -u nocasematch
  return 1
}

# guard_reconstruct_segment <raw-command> <segment> — <segment>, extended to
# wherever <raw-command> actually continues instead of stopping where
# guard_segments cut it. guard_segments only ever cuts *after* some point, it
# never rewrites what came before, so a (trimmed) segment is always a literal
# prefix of <raw-command> starting at the point it was taken from; this finds
# that point and reattaches the rest. First occurrence wins if <segment>
# happens to appear more than once (e.g. two byte-identical invocations) —
# the same corner case guard_heredoc_body_for accepts, for the same reason.
guard_reconstruct_segment() {
  local raw="$1" seg
  seg="$(guard_trim "$2")"
  [ -n "$seg" ] || return 1
  case "$raw" in
    *"$seg"*) printf '%s' "$seg${raw#*"$seg"}"; return 0 ;;
  esac
  return 1
}

# guard_sql_unescape <text> — `\"` and `\'` collapsed to a bare quote.
#
# A command that reaches the client through another shell arrives escaped:
# `ssh dbhost "mysql -e \"drop table t\""`. Without this the value extraction
# below sees `\"drop` — not a quote it recognises, and not a token equal to
# `drop` either — and the whole statement passes silently, which is precisely
# the case the remote-wrapper target ("(remote via ssh)") exists to prompt for.
guard_sql_unescape() {
  local t="$1"
  t="${t//\\\"/\"}"
  t="${t//\\\'/\'}"
  printf '%s' "$t"
}

# guard_sql_invocation_text <text> — <text> cut at the first `;`, `&`, `|` or
# newline that is *outside* quotes.
#
# The bound guard_reconstruct_segment cannot supply: it reattaches everything
# to the end of the command line, so without this a later command's payload is
# read as this segment's. `psql -h prod -c "select count(*) from t; truncate
# table sessions" && psql -h localhost -c "select 1"` is the case that made
# this necessary — the `(` split the segment, the repair ran to end of line,
# and the production TRUNCATE was classified on the trailing "select 1".
#
# awk, not a bash loop: `${s:$i:1}` is O(i) under a multibyte locale and
# `out="$out$c"` copies the accumulator every step, so the obvious shell
# version is quadratic twice over. A 9 KB inline statement — one `-e "…"` with
# a couple of thousand ids in it, which is an ordinary thing for an agent to
# write — took the hook from milliseconds to minutes, i.e. it hung the tool
# call. One fork that runs only for a mysql/psql segment is the cheap side of
# that trade.
#
# Newlines: an *unquoted* one ends the invocation like any other separator, but
# one inside an open quote belongs to the statement, so the scan carries its
# quote state across lines.
guard_sql_invocation_text() {
  printf '%s' "$1" | awk '
    function scan(s,   i, n, c) {
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") { i++; continue }
        if (q != "") { if (c == q) q = ""; continue }
        if (c == "\"" || c == "'"'"'") { q = c; continue }
        if (c == ";" || c == "&" || c == "|") return i - 1
      }
      return -1
    }
    { cut = scan($0)
      if (cut >= 0) { printf "%s%s", pre, substr($0, 1, cut); exit }
      if (q != "") { pre = pre $0 "\n"; next }
      printf "%s%s", pre, $0; exit
    }
  '
}

# guard_sql_strip_quotes <text> — one layer of surrounding quotes removed.
guard_sql_strip_quotes() {
  printf '%s' "$1" | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

# guard_sql_flag_values <text> <flag-alternation> — every value the flag takes
# in <text>, one per line, outer quotes removed.
#
# All of them, not just the first: `mysql -e "select 1" -e "drop table t"` runs
# both. Unlike guard_flag_value in guard-lib.sh, which always stops at the
# first whitespace — fine for a hostname, wrong for SQL text with spaces in it.
# The leading `(^|[[:space:]])` keeps `-e` from matching inside a longer word.
guard_sql_flag_values() {
  local text="$1" flags="$2" v
  printf '%s' "$text" \
    | grep -oE -- "(^|[[:space:]])($flags)[= ](\"[^\"]*\"|'[^']*'|[^[:space:]]+)" \
    | sed -E "s/^[[:space:]]*($flags)[= ]//" \
    | while IFS= read -r v; do guard_sql_strip_quotes "$v"; printf '\n'; done
}

# guard_sql_herestring <text> — the SQL of a `<<<` herestring, or nothing.
guard_sql_herestring() {
  printf '%s' "$1" \
    | grep -oE "<<<[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:]]+)" \
    | head -n1 \
    | sed -E 's/^<<<[[:space:]]*//' \
    | { IFS= read -r v && guard_sql_strip_quotes "$v"; }
}

# guard_sql_file_target <segment> [<flag-alternation>] — the file this
# segment reads SQL from: an explicit flag value (psql -f/--file; pass the
# alternation, mysql has no such flag) or a shell redirect
# (`mysql db < migrate.sql`, `psql db < migrate.sql`). Heredocs and herestrings
# are handled separately and stripped here first, so `<<EOF` is never misread
# as a `<` redirect into a file named "EOF".
guard_sql_file_target() {
  local seg="$1" flags="${2:-}" f cleaned
  if [ -n "$flags" ]; then
    f=$(printf '%s' "$seg" | grep -oE -- "($flags)[= ][^[:space:]]+" | head -n1 | sed -E "s/^($flags)[= ]//" | tr -d '"'"'"'')
    if [ -n "$f" ] && [ "$f" != '-' ]; then printf '%s' "$f"; return 0; fi
  fi
  cleaned=$(printf '%s' "$seg" | sed -E 's/<<<[^ ]*//g; s/<<-?[^ ]*//g')
  f=$(printf '%s' "$cleaned" | grep -oE '<[[:space:]]*[^[:space:];|&<>]+' | tail -n1)
  [ -n "$f" ] || return 1
  f="$(guard_trim "${f#<}")"
  [ -n "$f" ] || return 1
  printf '%s' "$f"
}

# guard_sql_file_contents <file> — bounded read (64 KiB, same cap
# guard_script_bodies uses), or nothing if unreadable.
guard_sql_file_contents() {
  local file="$1"
  case "$file" in "~/"*) file="$HOME/${file#\~/}" ;; esac
  [ -f "$file" ] && [ -r "$file" ] || return 1
  head -c 65536 "$file" 2>/dev/null
}

# guard_sql_pipe_input <raw-command> <segment> — the last pipeline stage
# feeding <segment>'s standard input, or 1 when <segment> is not a pipe sink.
# guard_segments splits on `|`, so the relationship only survives in the raw
# command line: everything before the segment, up to the `|` that feeds it.
guard_sql_pipe_input() {
  local raw="$1" seg pre up
  seg="$(guard_trim "$2")"
  [ -n "$seg" ] || return 1
  case "$raw" in
    *"$seg"*) pre="${raw%%"$seg"*}" ;;
    *) return 1 ;;
  esac
  pre="$(guard_trim "$pre")"
  case "$pre" in
    *'||') return 1 ;;   # a shell OR, not a pipe
    *'|') ;;
    *) return 1 ;;
  esac
  up="${pre%|}"
  # Only the stage that actually writes to the client: in `cat dump.sql |
  # gunzip | mysql` it is gunzip, and what cat read says nothing about it.
  up="${up##*[;&|]}"
  up="$(guard_trim "$up")"
  [ -n "$up" ] || return 1
  printf '%s' "$up"
}

# guard_sql_pipe_classify — classify what a pipe feeds into the client.
#
# Piping into a database client is executing arbitrary SQL against whatever
# target the client names; `mysql db < migrate.sql` and `cat migrate.sql |
# mysql db` are the same operation written two ways, and only the first was
# ever visible to this guard. Where the producer is text this file can read
# (echo/printf/cat) it is scanned like any other payload and a read-only
# pipeline stays silent. Where it is opaque — mysqldump, pg_dump, curl, gunzip,
# a script — there is nothing to scan and the invocation asks: a restore is not
# a thing to discover afterwards.
guard_sql_pipe_classify() {
  local up head kw sql t i n
  up=$(guard_sql_pipe_input "$GUARD_RAW_CMD" "$GUARD_SEG") || return 1
  guard_tokenize "$up"
  n=${#GUARD_TOKENS[@]}
  [ $n -gt 0 ] || return 1
  head="${GUARD_TOKENS[0]##*/}"

  case "$head" in
    echo|printf)
      # An inline string, so the quotes are the shell's and carry no SQL
      # meaning: strip them all rather than one outer layer, or `echo -e
      # "drop …"` hides behind its flag.
      sql="$(guard_trim "${up#*"${GUARD_TOKENS[0]}"}")"
      sql="${sql//\"/}"
      sql="${sql//\'/}"
      kw=$(guard_sql_destructive_word "$sql") || return 1
      GUARD_ACTION="SQL $kw (piped)"
      return 0 ;;
    cat)
      i=1
      while [ $i -lt $n ]; do
        t="${GUARD_TOKENS[$i]}"
        i=$((i + 1))
        case "$t" in -*) continue ;; esac
        sql=$(guard_sql_file_contents "$t") || continue
        kw=$(guard_sql_destructive_word "$sql") || continue
        GUARD_ACTION="SQL $kw (piped from $t)"
        return 0
      done
      return 1 ;;
  esac

  GUARD_ACTION="piped SQL (from $head)"
  return 0
}

# guard_sql_classify — the shared guard_classify_extra body for both profiles.
# Each payload channel in turn, stopping at the first destructive keyword:
# inline -e/-c values, herestring, heredoc body, `-f`/redirected file, and
# finally standard input from a pipe — which is only consulted when no other
# channel supplied a statement, since a client given -e/-f never reads stdin.
#   $1 — file flags (psql: '-f|--file'; mysql has none, pass '')
#   $2 — inline-statement flags (mysql: '-e|--execute'; psql: '-c|--command')
guard_sql_classify() {
  local file_flags="${1:-}" value_flags="${2:-}" kw sql file full had_payload=0

  full=$(guard_reconstruct_segment "$GUARD_RAW_CMD" "$GUARD_SEG") || full="$GUARD_SEG"
  full=$(guard_sql_invocation_text "$(guard_sql_unescape "$full")")

  if [ -n "$value_flags" ]; then
    while IFS= read -r sql; do
      [ -n "$sql" ] || continue
      had_payload=1
      kw=$(guard_sql_destructive_word "$sql") || continue
      GUARD_ACTION="SQL $kw"
      return 0
    done <<EOF
$(guard_sql_flag_values "$full" "$value_flags")
EOF
  fi

  sql=$(guard_sql_herestring "$full")
  if [ -n "$sql" ]; then
    had_payload=1
    kw=$(guard_sql_destructive_word "$sql")
    if [ -n "$kw" ]; then
      GUARD_ACTION="SQL $kw (herestring)"
      return 0
    fi
  fi

  case "$GUARD_SEG" in
    *'<<'*)
      sql=$(guard_heredoc_body_for "$GUARD_RAW_CMD" "$GUARD_SEG")
      if [ -n "$sql" ]; then
        had_payload=1
        kw=$(guard_sql_destructive_word "$sql")
        if [ -n "$kw" ]; then
          GUARD_ACTION="SQL $kw (heredoc)"
          return 0
        fi
      fi ;;
  esac

  # Safety net for a payload shaped some way none of the channels above
  # recognise — the same "loose match still catches it" role
  # guard_embedded_invocation plays for wrapped mentions elsewhere. Scans the
  # invocation's words as written, quotes included, so it adds catches without
  # adding the false positives blanket quote-stripping would.
  kw=$(guard_sql_destructive_word "$full")
  if [ -n "$kw" ]; then
    GUARD_ACTION="SQL $kw"
    return 0
  fi

  file=$(guard_sql_file_target "$GUARD_SEG" "$file_flags")
  if [ -n "$file" ]; then
    sql=$(guard_sql_file_contents "$file")
    if [ -n "$sql" ]; then
      had_payload=1
      kw=$(guard_sql_destructive_word "$sql")
      if [ -n "$kw" ]; then
        GUARD_ACTION="SQL $kw (file $file)"
        return 0
      fi
    fi
  fi

  [ "$had_payload" = 0 ] || return 1
  guard_sql_pipe_classify
}
