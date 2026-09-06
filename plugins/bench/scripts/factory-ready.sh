#!/usr/bin/env bash
# scripts/factory-ready.sh — implements factory-protocol.md §5 "ready":
#
#   ready = open ∧ factory:ready ∧ ¬factory:in-progress ∧ ¬needs-human ∧ ¬type:epic
#           ∧ every issue referenced in the body's "## Blocked by" section is closed
#           ∧ every native `blocked by` dependency (best-effort, via gh api) is closed
#
# Prints one issue number per line (default) or a JSON array (--json).
#
# `parse_blocked_by` (the body-parsing function) has no network dependency and
# is unit-tested by sourcing this file — see tests/factory_ready.bats. The
# BASH_SOURCE guard below means `source factory-ready.sh` defines the
# functions without running main or requiring gh.
set -uo pipefail

die() { printf 'factory-ready: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
factory-ready.sh — list issues ready for dispatch (factory-protocol.md §5).

Usage:
  factory-ready.sh [--repo owner/name] [--json]

Prints one ready issue number per line, or a JSON array with --json.
USAGE
}

# parse_blocked_by <body> — print the issue numbers (one per line, sorted,
# deduped) referenced under the body's "## Blocked by" heading only. Refs
# anywhere else in the body (Source, Notes, prose) are ignored: the section
# is the portable dependency record, not every #n mention.
parse_blocked_by() {
  local body="$1"
  awk '
    BEGIN { insec = 0 }
    /^##[[:space:]]/ {
      if (insec) exit
      if (tolower($0) ~ /^##[[:space:]]+blocked by[[:space:]]*$/) { insec = 1 }
      next
    }
    insec { print }
  ' <<<"$body" | grep -oE '#[0-9]+' | tr -d '#' | sort -n -u || true
}

# issue_is_open <repo> <number> — best-effort: prints "open" or "closed"; on
# any lookup failure prints nothing and the caller treats that blocker as
# unknown (never blocking, since we cannot tell a stale ref from a real one).
issue_is_open() {
  gh issue view "$2" --repo "$1" --json state --jq '.state' 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# native_blocked_by_open <repo> <number> — best-effort list of numbers this
# issue is natively blocked by (via the dependencies API) that are still open.
# Prints nothing (not an error) if the endpoint is unavailable.
native_blocked_by_open() {
  gh api "repos/$1/issues/$2/dependencies/blocked_by" --jq '.[] | select(.state == "open") | .number' 2>/dev/null || true
}

main() {
  local repo="" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; [ -n "$repo" ] || die "--repo needs owner/name"; shift 2 ;;
      --repo=*) repo="${1#*=}"; shift ;;
      --json) as_json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed or not on PATH."
  [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  [ -n "$repo" ] || die "could not determine --repo; pass --repo owner/name."

  local listing
  listing="$(gh issue list --repo "$repo" --label factory:ready --state open \
    --json number,body,labels --limit 500 2>/dev/null)" \
    || die "gh issue list failed for $repo"

  # Drop factory:in-progress / needs-human / type:epic here; body-parsing and
  # native-dependency checks happen per-issue below.
  local candidates
  candidates="$(printf '%s' "$listing" | jq -c '
    .[] | select(
      ([.labels[].name] | index("factory:in-progress") | not) and
      ([.labels[].name] | index("needs-human") | not) and
      ([.labels[].name] | index("type:epic") | not)
    ) | {number, body: (.body // "")}
  ')"

  local ready=()
  local row number body b state n blocked
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    number="$(printf '%s' "$row" | jq -r '.number')"
    body="$(printf '%s' "$row" | jq -r '.body')"

    blocked=0

    while IFS= read -r b; do
      [ -n "$b" ] || continue
      state="$(issue_is_open "$repo" "$b")"
      if [ "$state" = "open" ]; then blocked=1; break; fi
    done < <(parse_blocked_by "$body")

    if [ "$blocked" -eq 0 ]; then
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        blocked=1; break
      done < <(native_blocked_by_open "$repo" "$number")
    fi

    [ "$blocked" -eq 0 ] && ready+=("$number")
  done < <(printf '%s\n' "$candidates")

  if [ "$as_json" -eq 1 ]; then
    if [ "${#ready[@]}" -eq 0 ]; then printf '[]\n'; else printf '%s\n' "${ready[@]}" | jq -sc 'map(tonumber)'; fi
  elif [ "${#ready[@]}" -gt 0 ]; then
    printf '%s\n' "${ready[@]}"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
