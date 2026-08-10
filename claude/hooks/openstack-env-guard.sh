#!/bin/bash
# PreToolUse hook (Bash matcher): force explicit user confirmation for
# destructive `openstack` CLI commands.
#
# OpenStack has no local-safe target (no devstack/minikube equivalent in this
# setup's clouds.yaml — every configured cloud is a real environment), so
# every mutating command gets permissionDecision "ask". Read-only commands
# (list/show/find and bare `openstack` help) pass through to the normal
# permission flow. The detected cloud (--os-cloud / OS_CLOUD / OS_CLOUD_NAME)
# is surfaced in the reason so the target can be sanity-checked before approving.
#
# The verb is looked for among *positional* words only, so flag values like
# `openstack server list --name delete-me-later` no longer trip the guard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

cmd=$(guard_input_command) || exit 0
[ -n "$cmd" ] || exit 0

# Destructive / mutating action verbs used across `openstack <object> <verb>`
# subcommands (server/volume/image/network/stack/... all share this verb set).
OS_DESTRUCTIVE='create|delete|remove|add|set|unset|update|reboot|rebuild|resize|migrate|live-migrate|evacuate|shelve|unshelve|suspend|resume|pause|unpause|stop|start|restart|lock|unlock|rescue|unrescue|failover|force-delete|save|restore|revert|attach|detach|associate|disassociate|allocate|release|assign|unassign|apply|deploy|adopt|abandon|purge|revoke|trust'
# Read-only verbs. Listed so that a read verb appearing before a destructive
# word (`openstack server list` on a host called "restart-me") wins.
OS_READONLY='list|show|find|get|describe|check|validate|history|log|stats|usage'
# Boolean global flags — must be known so they do not swallow the next word.
OS_BOOLS='--debug|--verbose|-v|--quiet|-q|--insecure|--os-beta-command|--enable|--disable|--long|--yes|--force|--wait|--no-wait|--all|--all-projects'

action=""

classify() {
  guard_is_help && return 1
  guard_positionals "$OS_BOOLS"
  local verb
  verb=$(guard_pos_match "${OS_DESTRUCTIVE}|${OS_READONLY}") || return 1
  [[ "$verb" =~ ^($OS_DESTRUCTIVE)$ ]] || return 1
  action="$verb"
  return 0
}

# seg_cloud <segment> — the cloud the *classified invocation* targets. Read per
# segment: `openstack --os-cloud staging server list && openstack --os-cloud
# production server delete web-1` deletes on production, and a whole-command
# grep would put "staging" in the prompt for it. Every mutation asks either way,
# but a prompt that names the wrong environment is how the wrong one gets
# approved. --os-cloud wins, then an OS_CLOUD/OS_CLOUD_NAME prefix on the
# command, then the shell's env.
seg_cloud() {
  local seg="$1" cloud
  cloud=$(printf '%s' "$seg" | grep -oE -- '--os-cloud[= ][^[:space:]]+' | head -n1 | sed -E 's/^--os-cloud[= ]//' | tr -d '"'"'"'')
  if [ -z "$cloud" ]; then
    cloud=$(printf '%s' "$seg" | grep -oE '(^|[;&|[:space:]])OS_CLOUD(_NAME)?=[^[:space:]]+' | head -n1 | sed -E 's/.*OS_CLOUD(_NAME)?=//' | tr -d '"'"'"'')
  fi
  if [ -z "$cloud" ]; then
    cloud="${OS_CLOUD:-${OS_CLOUD_NAME:-}}"
  fi
  # Custom clouds.yaml location makes the target harder to verify at a glance.
  if printf '%s' "$seg" | grep -qE -- '--os-cloud-config|(^|[;&|[:space:]])OS_CLIENT_CONFIG_FILE='; then
    cloud="${cloud:-unknown} (custom clouds.yaml)"
  fi
  printf '%s' "$cloud"
}

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  guard_reaches openstack "$seg" || continue
  classify || continue
  cloud=$(seg_cloud "$seg")
  guard_ask "Destructive openstack \"$action\" targets cloud \"${cloud:-unknown}\". OpenStack has no local-safe target; explicit user confirmation required."
done <<EOF
$(guard_segments "$cmd")
EOF

exit 0
