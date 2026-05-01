#!/bin/sh
input=$(cat)

model=$(echo "$input"       | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input"        | jq -r '.context_window.used_percentage // empty')
worktree=$(echo "$input"    | jq -r '.worktree.name // empty')
session_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .worktree.original_cwd // empty')
effort=$(echo "$input"      | jq -r '.effort.level // empty')
session_id=$(echo "$input"  | jq -r '.session_id // "default"')
# ── Accumulated total cost across sessions ───────────────────────────────────
COST_SESSION_FILE="${HOME}/.claude/session-cost-${session_id}"
TOTAL_COST_FILE="${HOME}/.claude/accumulated_cost.txt"

if [ -n "$session_cost" ]; then
  prev_session_cost=$(cat "$COST_SESSION_FILE" 2>/dev/null || echo "0")
  delta=$(awk "BEGIN { d = $session_cost - $prev_session_cost; print (d > 0) ? d : 0 }")
  echo "$session_cost" > "$COST_SESSION_FILE"
  if awk "BEGIN { exit ($delta <= 0) }"; then
    prev_total=$(cat "$TOTAL_COST_FILE" 2>/dev/null || echo "0")
    awk "BEGIN { printf \"%.6f\n\", $prev_total + $delta }" > "$TOTAL_COST_FILE"
  fi
fi
total_cost=$(cat "$TOTAL_COST_FILE" 2>/dev/null || echo "0")

rl_5h_pct=$(echo "$input"   | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl_5h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
rl_7d_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl_7d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RED=$(printf '\033[31m')
BLUE=$(printf '\033[34m')
MAGENTA=$(printf '\033[35m')
CYAN=$(printf '\033[36m')
WHITE=$(printf '\033[37m')
BOLD=$(printf '\033[1m')
RESET=$(printf '\033[0m')

# ANSI color based on percentage: 0-49 green, 50-74 yellow, 75+ red
color_for_pct() {
  pct=$(printf "%.0f" "${1:-0}" 2>/dev/null || echo 0)
  if   [ "$pct" -ge 75 ]; then printf "%s" "$RED"
  elif [ "$pct" -ge 50 ]; then printf "%s" "$YELLOW"
  else printf "%s" "$GREEN"
  fi
}

# 10-segment progress bar using ▰▱
make_bar() {
  pct=$(printf "%.0f" "${1:-0}" 2>/dev/null || echo 0)
  filled=$(( pct * 10 / 100 )); bar=""; i=0
  while [ $i -lt $filled ]; do bar="${bar}▰"; i=$(( i + 1 )); done
  while [ $i -lt 10 ];       do bar="${bar}▱"; i=$(( i + 1 )); done
  printf "%s" "$bar"
}

# Elapsed time since window start = window_secs - (resets_at - now)
elapsed_str() {
  reset_at="$1"; window_secs="$2"
  now=$(date +%s)
  remaining=$(( reset_at - now ))
  [ "$remaining" -lt 0 ] && remaining=0
  elapsed=$(( window_secs - remaining ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  d=$(( elapsed / 86400 ))
  h=$(( (elapsed % 86400) / 3600 ))
  m=$(( (elapsed % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf "%dd %dh %dm" "$d" "$h" "$m"
  elif [ "$h" -gt 0 ]; then printf "%dh %dm" "$h" "$m"
  else printf "%dm" "$m"
  fi
}

# Format cost as $X.XX
fmt_cost() {
  [ -n "$1" ] && awk "BEGIN { printf \"\$%.2f\", $1 }" || printf '$0.00'
}

# Effort label with color
effort_label() {
  case "$1" in
    low)    printf "${GREEN}${BOLD}⚡ low${RESET}" ;;
    medium) printf "${YELLOW}${BOLD}⚡ medium${RESET}" ;;
    high)   printf "${RED}${BOLD}⚡ high${RESET}" ;;
    xhigh)  printf "${RED}${BOLD}⚡⚡ xhigh${RESET}" ;;
    max)    printf "${RED}${BOLD}⚡⚡ max${RESET}" ;;
    *)      printf "⚡ %s" "$1" ;;
  esac
}

# ── Git info with caching (5s TTL, keyed by session_id) ──────────────────────

ref_dir="${current_dir:-.}"
CACHE_FILE="/tmp/statusline-git-${session_id}"
CACHE_TTL=5

cache_is_stale() {
  [ ! -f "$CACHE_FILE" ] && return 0
  mtime=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - mtime )) -gt $CACHE_TTL ]
}

if cache_is_stale; then
  if git -C "$ref_dir" rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git -C "$ref_dir" branch --show-current 2>/dev/null)
    commit=""
    if [ -z "$branch" ]; then
      commit=$(git -C "$ref_dir" rev-parse --short HEAD 2>/dev/null)
    fi

    # In-progress action (rebase / merge / cherry-pick)
    action=""
    git_dir=$(git -C "$ref_dir" rev-parse --absolute-git-dir 2>/dev/null)
    if [ -n "$git_dir" ]; then
      if   [ -d "${git_dir}/rebase-merge" ] || [ -d "${git_dir}/rebase-apply" ]; then action="rebase"
      elif [ -f "${git_dir}/MERGE_HEAD" ];       then action="merge"
      elif [ -f "${git_dir}/CHERRY_PICK_HEAD" ]; then action="cherry-pick"
      elif [ -f "${git_dir}/REVERT_HEAD" ];      then action="revert"
      elif [ -f "${git_dir}/BISECT_LOG" ];       then action="bisect"
      fi
    fi

    # Ahead / behind upstream
    ahead=$(git -C "$ref_dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
    behind=$(git -C "$ref_dir" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)

    # Index changes
    staged=$(git -C "$ref_dir" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    renamed=$(git -C "$ref_dir" diff --cached --name-status 2>/dev/null | grep '^R' | wc -l | tr -d ' ')

    # Worktree changes
    modified=$(git -C "$ref_dir" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    deleted=$(git -C "$ref_dir" ls-files --deleted 2>/dev/null | wc -l | tr -d ' ')

    # Unmerged / untracked / stashed
    unmerged=$(git -C "$ref_dir" diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git -C "$ref_dir" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    stashed=$(git -C "$ref_dir" stash list 2>/dev/null | wc -l | tr -d ' ')

    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$branch" "$commit" "$action" \
      "$ahead" "$behind" \
      "$staged" "$deleted" "$modified" "$renamed" "$unmerged" "$untracked" "$stashed" \
      > "$CACHE_FILE"
  else
    printf "||||0|0|0|0|0|0|0|0\n" > "$CACHE_FILE"
  fi
fi

# Read cache — IFS='|' read needs exactly 12 fields
git_branch=""; git_commit=""; git_action=""
git_ahead=0; git_behind=0
git_staged=0; git_deleted=0; git_modified=0; git_renamed=0
git_unmerged=0; git_untracked=0; git_stashed=0

if [ -f "$CACHE_FILE" ]; then
  saved=$(cat "$CACHE_FILE")
  git_branch=$(echo "$saved"   | cut -d'|' -f1)
  git_commit=$(echo "$saved"   | cut -d'|' -f2)
  git_action=$(echo "$saved"   | cut -d'|' -f3)
  git_ahead=$(echo "$saved"    | cut -d'|' -f4)
  git_behind=$(echo "$saved"   | cut -d'|' -f5)
  git_staged=$(echo "$saved"   | cut -d'|' -f6)
  git_deleted=$(echo "$saved"  | cut -d'|' -f7)
  git_modified=$(echo "$saved" | cut -d'|' -f8)
  git_renamed=$(echo "$saved"  | cut -d'|' -f9)
  git_unmerged=$(echo "$saved" | cut -d'|' -f10)
  git_untracked=$(echo "$saved"| cut -d'|' -f11)
  git_stashed=$(echo "$saved"  | cut -d'|' -f12)
fi

# Format sorin-style git segment
git_str=""
if [ -n "$git_branch" ]; then
  git_str="${GREEN}${BOLD}${git_branch}${RESET}"
elif [ -n "$git_commit" ]; then
  git_str="${YELLOW}${BOLD}${git_commit}${RESET}"
fi
[ -n "$git_action" ]         && git_str="${git_str}${WHITE}:${RESET}${RED}${BOLD}${git_action}${RESET}"
[ "$git_ahead" -gt 0 ]      2>/dev/null && git_str="${git_str} ${MAGENTA}${BOLD}⬆${git_ahead}${RESET}"
[ "$git_behind" -gt 0 ]     2>/dev/null && git_str="${git_str} ${MAGENTA}${BOLD}⬇${git_behind}${RESET}"
[ "$git_stashed" -gt 0 ]    2>/dev/null && git_str="${git_str} ${CYAN}${BOLD}✭${git_stashed}${RESET}"
[ "$git_staged" -gt 0 ]     2>/dev/null && git_str="${git_str} ${GREEN}${BOLD}✚${git_staged}${RESET}"
[ "$git_deleted" -gt 0 ]    2>/dev/null && git_str="${git_str} ${RED}${BOLD}✖${git_deleted}${RESET}"
[ "$git_modified" -gt 0 ]   2>/dev/null && git_str="${git_str} ${BLUE}${BOLD}✱${git_modified}${RESET}"
[ "$git_renamed" -gt 0 ]    2>/dev/null && git_str="${git_str} ${MAGENTA}${BOLD}➜${git_renamed}${RESET}"
[ "$git_unmerged" -gt 0 ]   2>/dev/null && git_str="${git_str} ${YELLOW}${BOLD}═${git_unmerged}${RESET}"
[ "$git_untracked" -gt 0 ]  2>/dev/null && git_str="${git_str} ${WHITE}${BOLD}◼${git_untracked}${RESET}"

# ── Line 1: 📁 dir | 🌿 git | [🌳 worktree |] 🤖 model | ⚡ effort | 🧠 context% ──

repo_root=$(git -C "$ref_dir" rev-parse --show-toplevel 2>/dev/null || echo "$ref_dir")
dir_display=$(basename "${repo_root:-$ref_dir}")

line1="📁 ${dir_display}"
[ -n "$git_str" ]  && line1="${line1} | 🌿 ${git_str}"
[ -n "$worktree" ] && line1="${line1} | 🌳 ${worktree}"
line1="${line1} | 🤖 ${model}"
[ -n "$effort" ]   && line1="${line1} | $(effort_label "$effort")"

used_int=$(printf "%.0f" "${used:-0}" 2>/dev/null || echo 0)
mem_color=$(color_for_pct "$used_int")
line1="${line1} | 🧠 ${mem_color}${used_int}%${RESET}"

# ── Line 2: 5h bar ↻ elapsed (💰 $cost) ────────────────────────────────────

line2=""
if [ -n "$rl_5h_pct" ] && [ -n "$rl_5h_reset" ]; then
  c=$(color_for_pct "$rl_5h_pct")
  bar=$(make_bar "$rl_5h_pct")
  pct_int=$(printf "%.0f" "$rl_5h_pct")
  elapsed=$(elapsed_str "$rl_5h_reset" 18000)
  line2="${c}${bar} ${pct_int}%${RESET} ↻ ${elapsed} (💰 $(fmt_cost "$session_cost"))"
fi

# ── Line 3: 7d bar ↻ elapsed (💰 $total) ────────────────────────────────────

line3=""
if [ -n "$rl_7d_pct" ] && [ -n "$rl_7d_reset" ]; then
  c=$(color_for_pct "$rl_7d_pct")
  bar=$(make_bar "$rl_7d_pct")
  pct_int=$(printf "%.0f" "$rl_7d_pct")
  elapsed=$(elapsed_str "$rl_7d_reset" 604800)
  line3="${c}${bar} ${pct_int}%${RESET} ↻ ${elapsed} (💰 $(fmt_cost "$total_cost"))"
fi

printf "%s\n%s\n%s\n" "$line1" "$line2" "$line3"
