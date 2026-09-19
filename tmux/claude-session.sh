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
    cat >/dev/null
    [ -n "${TMUX_PANE:-}" ] || exit 0
    tmux set-option -p -u -t "$TMUX_PANE" @claude-session
    ;;
  save)
    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@claude-session}' |
      awk 'NF == 2' >| "${file}.tmp" && mv -f "${file}.tmp" "$file"
    ;;
  restore)
    [ -r "$file" ] || exit 0
    while read -r pane id; do
      tmux send-keys -t "=${pane}" "claude --resume ${id}" Enter
    done < "$file"
    ;;
esac
exit 0
