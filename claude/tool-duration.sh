#!/bin/sh
## PostToolUse / PostToolUseFailure hook: how long a tool call ran, shown under
## it as "PostToolUse:Bash says: ⏱ 12.3s". Claude Code hands the hook
## duration_ms; a systemMessage is drawn for the user only and never sent to the
## model, so the line costs no context. Registered for Bash in settings.json.
command -v jq >/dev/null 2>&1 || exit 0
jq -c '
  def pad: tostring | if length < 2 then "0" + . else . end;
  select(.duration_ms != null)
  | (.duration_ms | floor) as $ms
  | ($ms / 1000 | floor) as $s
  | if   $ms < 1000 then "\($ms)ms"
    elif $s < 60    then "\(($ms / 100 | floor) / 10)s"
    elif $s < 3600  then "\($s / 60 | floor)m \($s % 60 | pad)s"
    else                 "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor | pad)m"
    end
  | {systemMessage: ("⏱ " + .)}
' 2>/dev/null
exit 0
