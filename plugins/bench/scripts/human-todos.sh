#!/usr/bin/env bash
# scripts/human-todos.sh — SessionStart hook: surface the current user's open
# `human:todo` issues (docs/factory-protocol.md §15) so a new session starts
# with the outstanding asks in view instead of them being forgotten in a
# closed chat transcript.
#
# Best-effort: every path exits 0. Silent (no output at all) when `gh` is
# missing, unauthenticated, not run inside a repo, or there is nothing to
# report — this hook only ever adds a line when there's something to see.
set -uo pipefail

# stdout on purpose: a SessionStart hook's stdout is added to the session's context, so
# the agent sees the open asks and can raise them; stderr would only reach the terminal.
log() { printf '[human-todos] %s\n' "$*"; }

REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

command -v gh >/dev/null 2>&1 || exit 0

RUN() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 "$@"
  else
    "$@"
  fi
}

RUN gh auth status >/dev/null 2>&1 || exit 0

REPO_ARGS=()
[ -n "$REPO" ] && REPO_ARGS=(--repo "$REPO")

listing="$(RUN gh issue list "${REPO_ARGS[@]+"${REPO_ARGS[@]}"}" --label human:todo --assignee @me --state open \
  --json number,title,body 2>/dev/null)" || exit 0

[ -n "$listing" ] || exit 0

# parse_blocks <body> — print the first `- #<n>` line under a `## Blocks`
# heading, or nothing if there's no such section/ref. Mirrors
# factory-ready.sh's parse_blocked_by: only the named section counts, and it
# stops at the next heading.
parse_blocks() {
  local body="$1"
  awk '
    BEGIN { insec = 0 }
    /^##[[:space:]]/ {
      if (insec) exit
      if (tolower($0) ~ /^##[[:space:]]+blocks[[:space:]]*$/) { insec = 1 }
      next
    }
    insec { print }
  ' <<<"$body" | grep -oE '#[0-9]+' | head -1
}

count="$(printf '%s' "$listing" | jq 'length' 2>/dev/null)" || exit 0
[ -n "$count" ] && [ "$count" -gt 0 ] || exit 0

log "$count open to-do(s) for you:"

printf '%s' "$listing" | jq -c '.[]' | while IFS= read -r row; do
  [ -n "$row" ] || continue
  number="$(printf '%s' "$row" | jq -r '.number')"
  title="$(printf '%s' "$row" | jq -r '.title')"
  body="$(printf '%s' "$row" | jq -r '.body // ""')"
  blocks="$(parse_blocks "$body")"
  if [ -n "$blocks" ]; then
    log "  #$number $title  (blocks $blocks)"
  else
    log "  #$number $title"
  fi
done

exit 0
