# Shared origin-repo resolution for the gh and glab profiles. Not a profile
# itself (the dispatcher only globs *.guard), sourced by both.

# guard_scm_origin_slug — `host/owner/repo` for the repository the current
# working directory pushes to, or nothing.
#
# Parsed locally from the git remote rather than asked of `gh`/`glab`, so
# resolving a target never costs an API round-trip. The host is kept because it
# is the part that distinguishes a company GHES/self-hosted GitLab from the
# public instance, which is exactly what the prompt needs to show.
guard_scm_origin_slug() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || return 0
  [ -n "$url" ] || return 0
  url="${url#*://}"     # https://host/owner/repo -> host/owner/repo
  url="${url#*@}"       # git@host:owner/repo and https://user:token@host/... -> host...
  url="${url%.git}"
  printf '%s' "$url" | tr ':' '/'
}
