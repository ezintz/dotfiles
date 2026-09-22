#!/bin/sh
## Remembers which Claude Code conversation runs in which tmux pane, so that a
## restore after a reboot resumes that exact conversation (`claude --resume <id>`)
## instead of whichever one is newest in the directory.
##
## record / forget -- Claude Code's SessionStart / SessionEnd hooks
##   (claude/settings.json). They read the hook JSON on stdin and set or clear
##   @claude-session on the pane Claude runs in. SessionStart fires again with
##   the new id on /clear and compaction, so the pane always holds the live one.
## save / restore -- tmux-resurrect's post-save-all / post-restore-all hooks
##   (tmux/tmux.conf). resurrect does not save pane options, hence the side file,
##   which lives next to resurrect's own save so the two describe the same moment.

file="${HOME}/.local/share/tmux/resurrect/claude-sessions"

case "${1:-}" in
  record)
    [ -n "${TMUX_PANE:-}" ] || exit 0
    id="$(jq -r '.session_id // empty' 2>/dev/null)"
    [ -n "$id" ] && tmux set-option -p -t "$TMUX_PANE" @claude-session "$id"
    ;;
  forget)
    ## Only when the user ended the conversation. Killing tmux (a restart, a
    ## reboot) ends every Claude with reason "other" a moment before the last
    ## save, and forgetting then would leave that save with nothing to resume.
    reason="$(jq -r '.reason // empty' 2>/dev/null)"
    case "$reason" in clear|logout|prompt_input_exit) ;; *) exit 0 ;; esac
    [ -n "${TMUX_PANE:-}" ] || exit 0
    tmux set-option -p -u -t "$TMUX_PANE" @claude-session
    ;;
  save)
    [ -e "$file" ] || : >| "$file"
    ## A pane missing from the live list keeps its old entry: while tmux shuts
    ## down, saves still run as panes disappear one by one, and must not
    ## overwrite the full list with the few that are left. Stale entries are
    ## harmless -- restore only types into a pane still listed at the same
    ## coordinates.
    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@claude-session}' |
      awk 'FNR == NR { live[$1] = 1; if (NF == 2) print; next } !($1 in live)' - "$file" 2>/dev/null \
      >| "${file}.tmp" && mv -f "${file}.tmp" "$file"
    ;;
  restore)
    [ -r "$file" ] || exit 0
    ## Match the whole pane coordinate, not just the session. resurrect can
    ## recreate a session with a different layout, so session:0.1 may now be a
    ## different pane than the one the entry was written for -- and send-keys
    ## would type `claude --resume <someone else's id>` into whatever runs
    ## there. Whole-line match: a substring test would read 0:0.1 inside 0:0.10.
    live="$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"
    while read -r pane id; do
      printf '%s\n' "$live" | grep -qxF "$pane" || continue
      ## Record it before Claude does. Claude reports its id at SessionStart,
      ## seconds later, and a save in that window sees a live pane carrying no
      ## option: the merge above prints nothing for it and drops the old line
      ## too, because the line is only kept while the pane is absent from the
      ## live list. tmux.conf saves on a 300s timer, so the window is real.
      tmux set-option -p -t "=${pane}" @claude-session "$id"
      tmux send-keys -t "=${pane}" "claude --resume '${id}'" Enter
    done < "$file"
    ;;
esac
exit 0
