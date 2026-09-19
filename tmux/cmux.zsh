## Runs every interactive cmux terminal inside its own tmux session, so the shell
## and everything in it outlive cmux quitting, crashing or updating, and come
## back after a reboot through tmux-resurrect (configured in tmux/tmux.conf).
##
## Sourced from the top of zshrc, before Prezto, so the outer shell -- which only
## ever waits for the tmux client -- skips the expensive part of startup.
##
## The session is named after the cmux surface. cmux keeps a surface's id across
## restarts, so a restored tab lands straight back in the session it had.
##
## cmux's own agent auto-resume must stay off (terminal.autoResumeAgentSessions
## in cmux/cmux.json): it types `claude --resume` into the restored tab, which
## would start a second copy next to the one still running inside tmux.

[[ -o interactive && -z $TMUX && -n $CMUX_SURFACE_ID ]] || return 0
(( $+commands[tmux] )) || return 0

() {
  local session="cmux-${CMUX_SURFACE_ID}"
  local resurrect=~/.tmux/plugins/tmux-resurrect/scripts
  local saved=~/.local/share/tmux/resurrect/last

  ## The first cmux terminal to find no tmux server starts it and restores the
  ## last save. After a reboot cmux reopens every tab at once, so every tab takes
  ## the lock, and the rest wait behind the restore instead of each creating an
  ## empty session the restore would then skip. A lock older than any plausible
  ## restore (30s) was left by a shell that died holding it.
  local drop_bootstrap=0 lock="${TMPDIR:-/tmp}/cmux-tmux-restore.lock" tries=0
  until command mkdir "$lock" 2>/dev/null; do
    if (( ++tries > 300 )); then
      command rmdir "$lock" 2>/dev/null
      tries=0
    fi
    sleep 0.1
  done
  {
    if ! command tmux has-session 2>/dev/null; then
      ## tmux copies the environment it starts in into every future pane, so
      ## start it without this tab's cmux identity; each session gets its own
      ## below. resurrect only restores "from scratch" into a server holding a
      ## single pane in a session named 0, which it then removes. With nothing
      ## to restore, 0 is removed further down -- only once this tab's session
      ## exists, or the server would exit with its last session and the attach
      ## would start a new one carrying this tab's identity after all.
      (
        unset ${(k)parameters[(I)CMUX_*]} ${(k)parameters[(I)GHOSTTY_*]}
        command tmux new-session -d -s 0 -c ~
      )
      if [[ -e $saved ]]; then
        "$resurrect/restore.sh" >/dev/null 2>&1
      else
        drop_bootstrap=1
      fi
    fi
  } always {
    command rmdir "$lock"
  }

  ## This tab's cmux identity, set on the session so every pane in it reports to
  ## this tab. ZDOTDIR points zsh at cmux's integration bootstrap, which is how
  ## cmux itself loads it (sidebar directory, branch, ports); inside tmux that
  ## integration reads the workspace from the session environment. Re-set on
  ## every attach, since the socket and port change when cmux restarts.
  local -a cmux_env=(ZDOTDIR="$CMUX_SHELL_INTEGRATION_DIR" GHOSTTY_SURFACE_ID="$GHOSTTY_SURFACE_ID")
  local key
  for key in ${(k)parameters[(I)CMUX_*]}; do
    [[ ${parameters[$key]} == *export* ]] && cmux_env+=("$key=${(P)key}")
  done
  local -a env_args=()
  local kv
  for kv in $cmux_env; do env_args+=(-e "$kv"); done

  if command tmux has-session -t "=$session" 2>/dev/null; then
    for kv in $cmux_env; do
      command tmux set-environment -t "=$session" "${kv%%=*}" "${kv#*=}"
    done
  else
    command tmux new-session -d -s "$session" -c "$PWD" $env_args
  fi
  (( drop_bootstrap )) && command tmux kill-session -t '=0'

  ## Closing a cmux tab only detaches its session. Kill detached sessions whose
  ## tab no longer exists, but only when cmux answered with a list that includes
  ## this tab -- an empty or failed reply must not read as "every tab is gone".
  (
    local live
    live="$("${CMUX_BUNDLED_CLI_PATH:-cmux}" --id-format uuids tree --all --json 2>/dev/null)" || exit 0
    [[ $live == *$CMUX_SURFACE_ID* ]] || exit 0
    local name attached
    command tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null |
      while read -r name attached; do
        [[ $name == cmux-* && $attached == 0 && $live != *${name#cmux-}* ]] &&
          command tmux kill-session -t "=$name"
      done
  ) &!

  ## The status line duplicates cmux's own tab bar. Exiting the shell or
  ## detaching ends the tmux client with 0 and closes the tab; if tmux fails to
  ## start at all, fall through to an ordinary shell rather than a dead tab.
  command tmux attach-session -t "=$session" \; set-option status off && exit
  print -u2 "cmux.zsh: tmux failed, continuing with a plain shell"
}
