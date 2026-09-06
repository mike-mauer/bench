#!/usr/bin/env bash
# scripts/gh-issue-dep.sh — native GitHub sub-issue and issue-dependency edges,
# via `gh api`. Implements factory-protocol.md §5: parent/child uses the
# sub-issues endpoint, ordering uses the issue-dependencies "blocked by"
# endpoint. Both endpoints take the issue's numeric database *id*, not its
# number, so every subcommand resolves number → id first.
#
# Endpoint shapes used below (docs.github.com/en/rest/issues/sub-issues and
# /rest/issues/dependencies were unreachable from this environment when this
# script was written — network egress to docs.github.com is blocked here — so
# the shapes are the ones specified for this task, cross-checked against
# training knowledge of the GA REST API. Verify against a live `gh api` call if
# behavior looks wrong; corrections belong in this comment):
#
#   POST   /repos/{owner}/{repo}/issues/{n}/sub_issues              {sub_issue_id}
#   DELETE /repos/{owner}/{repo}/issues/{n}/sub_issue                {sub_issue_id}
#   GET    /repos/{owner}/{repo}/issues/{n}/sub_issues
#   POST   /repos/{owner}/{repo}/issues/{n}/dependencies/blocked_by  {issue_id}
#   DELETE /repos/{owner}/{repo}/issues/{n}/dependencies/blocked_by/{issue_id}
#   GET    /repos/{owner}/{repo}/issues/{n}/dependencies/blocked_by
#   GET    /repos/{owner}/{repo}/issues/{n}/dependencies/blocking
#
# Usage:
#   gh-issue-dep.sh [--repo owner/name] child   <parent> <child>
#   gh-issue-dep.sh [--repo owner/name] block   <issue>  <blocked-by>
#   gh-issue-dep.sh [--repo owner/name] unblock <issue>  <blocked-by>
#   gh-issue-dep.sh [--repo owner/name] list    <issue>
#
# <parent>/<child>/<issue>/<blocked-by> are issue NUMBERS (the #n you see in
# the UI). --repo defaults to `gh repo view`'s current repo.
set -uo pipefail

die() { printf 'gh-issue-dep: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
gh-issue-dep.sh — native GitHub sub-issue / dependency edges via gh api.

Usage:
  gh-issue-dep.sh [--repo owner/name] child   <parent> <child>
  gh-issue-dep.sh [--repo owner/name] block   <issue>  <blocked-by>
  gh-issue-dep.sh [--repo owner/name] unblock <issue>  <blocked-by>
  gh-issue-dep.sh [--repo owner/name] list    <issue>

child    — make <child> a sub-issue of <parent>.
block    — <issue> is blocked by <blocked-by> (dependency edge).
unblock  — remove that dependency edge.
list     — print <issue>'s sub-issues, blocked-by, and blocking issues.

--repo defaults to the current directory's repo (gh repo view).
USAGE
}

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed or not on PATH."

REPO=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; [ -n "$REPO" ] || die "--repo needs owner/name"; shift 2 ;;
    --repo=*) REPO="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO" ] || die "could not determine --repo; pass --repo owner/name (gh repo view failed — not in a repo?)."

SUB="$1"; shift || { usage >&2; die "missing subcommand"; }

# issue_db_id <number> → numeric database id (what the sub-issues and
# dependencies endpoints require; the #n number is not accepted there).
issue_db_id() {
  n="$1"
  id="$(gh api "repos/$REPO/issues/$n" --jq .id 2>/dev/null)" \
    || die "could not look up issue #$n in $REPO (gh api failed)."
  [ -n "$id" ] && [ "$id" != "null" ] || die "issue #$n in $REPO has no numeric id (does it exist?)."
  printf '%s\n' "$id"
}

case "$SUB" in
  child)
    parent="${1:-}"; child="${2:-}"
    [ -n "$parent" ] && [ -n "$child" ] || die "usage: child <parent> <child>"
    child_id="$(issue_db_id "$child")"
    gh api -X POST "repos/$REPO/issues/$parent/sub_issues" -F "sub_issue_id=$child_id" >/dev/null \
      || die "could not add #$child as a sub-issue of #$parent."
    printf 'added #%s as a sub-issue of #%s\n' "$child" "$parent"
    ;;

  block)
    issue="${1:-}"; blocked_by="${2:-}"
    [ -n "$issue" ] && [ -n "$blocked_by" ] || die "usage: block <issue> <blocked-by>"
    blocker_id="$(issue_db_id "$blocked_by")"
    gh api -X POST "repos/$REPO/issues/$issue/dependencies/blocked_by" -F "issue_id=$blocker_id" >/dev/null \
      || die "could not mark #$issue as blocked by #$blocked_by."
    printf '#%s is now blocked by #%s\n' "$issue" "$blocked_by"
    ;;

  unblock)
    issue="${1:-}"; blocked_by="${2:-}"
    [ -n "$issue" ] && [ -n "$blocked_by" ] || die "usage: unblock <issue> <blocked-by>"
    blocker_id="$(issue_db_id "$blocked_by")"
    gh api -X DELETE "repos/$REPO/issues/$issue/dependencies/blocked_by/$blocker_id" >/dev/null \
      || die "could not remove the #$blocked_by blocker from #$issue."
    printf 'removed #%s as a blocker of #%s\n' "$blocked_by" "$issue"
    ;;

  list)
    issue="${1:-}"
    [ -n "$issue" ] || die "usage: list <issue>"
    printf 'sub-issues:\n'
    gh api "repos/$REPO/issues/$issue/sub_issues" --jq '.[] | "  #\(.number)  \(.title)"' 2>/dev/null || true
    printf 'blocked by:\n'
    gh api "repos/$REPO/issues/$issue/dependencies/blocked_by" --jq '.[] | "  #\(.number)  \(.title)  (\(.state))"' 2>/dev/null || true
    printf 'blocking:\n'
    gh api "repos/$REPO/issues/$issue/dependencies/blocking" --jq '.[] | "  #\(.number)  \(.title)  (\(.state))"' 2>/dev/null || true
    ;;

  *)
    usage >&2
    die "unknown subcommand: $SUB"
    ;;
esac
