#!/usr/bin/env bash
# scripts/guard-bd-actor.sh — PreToolUse hook (matcher: Bash): require
# --actor= (or --actor <value>) inline on every bd WRITE verb.
#
# Write verbs: create, update, close, comment, dep, delete, reopen.
# Read-only verbs (list, show, comments, ready, stats, prime, ...) always
# pass. Pure string parsing — this guard NEVER shells out to bd and does no
# network I/O, so it stays fast on every Bash call.
#
# Input: PreToolUse JSON on stdin; tool_input.command holds the shell
# command Claude is about to run.
# https://code.claude.com/docs/en/hooks#pretooluse-input
#
# Exit 0 = allow (default; also the fail-open path for any parse error, and
# for non-Bash tool calls).
# Exit 2 = deny; stderr text is surfaced to Claude as the block reason.
set +e

input="$(cat 2>/dev/null)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command_str" ] || exit 0

# A command may chain multiple invocations with &&, ||, or ;. Evaluate each
# segment independently: a compliant `bd show ... --actor=x` must not
# shield a later non-compliant `bd close ...` in the same command. This is
# a best-effort lexical split (adequate for the shapes agents emit:
# straightforward chaining, not deliberately obfuscated shell).
#
# Deliberately does NOT split on raw newlines. A multi-line QUOTED argument
# (a commit message body, a heredoc body) routinely contains lines that
# start with a guarded token purely as prose — e.g.
# `bd comment X --actor=r "line one\nbd close Y"` or
# `git commit -m "impl guard\nbd close Bench-1 after merge"`. Splitting on
# bare newlines without quote/heredoc awareness turns that prose into its
# own bogus "command segment" and falsely denies a compliant or unrelated
# command (Bench-y4h round 1). The trade-off: a real newline-separated
# command chain outside of any quoting (`bd show X --actor=e\nbd close Y`)
# is now treated as a single segment and allowed if ANY --actor appears in
# it. False-allow is the tolerable direction for this convention guard;
# false-deny (blocking legitimate work) is not.
split_segments() {
  # NUL-delimited, not newline-delimited: `read` terminates a field on ANY
  # newline byte, so routing separators through \n can never coexist with
  # preserving a real newline that occurs INSIDE a segment (a quoted
  # commit-message body, a heredoc body). NUL cannot appear in a shell
  # command string, so it's a safe, unambiguous delimiter. The trailing ';'
  # guarantees the final segment is itself NUL-terminated — `read -d ''`
  # drops an unterminated final field otherwise (the same class of bug
  # already hit once with newline-terminated `read`).
  printf '%s;' "$1" | sed -E 's/&&|\|\|/;/g' | tr ';' '\000'
}

is_write_verb() {
  case "$1" in
    create|update|close|comment|dep|delete|reopen) return 0 ;;
    *) return 1 ;;
  esac
}

has_actor_flag() {
  # $1 = a single command segment. Matches --actor=value or --actor value
  # as a whole word, not a substring of some other flag/token.
  printf '%s' "$1" | grep -Eq -- '(^|[[:space:]])--actor(=|[[:space:]])'
}

while IFS= read -r -d '' segment; do
  [ -n "$segment" ] || continue

  # Strip leading VAR=value assignments (e.g. `PATH=... bd ...`), same
  # convention Claude Code itself uses for Bash `if` matching.
  trimmed="$segment"
  while [[ "$trimmed" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
    trimmed="${BASH_REMATCH[1]}"
  done
  # Trim leading whitespace.
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"

  # First whitespace-delimited token is the invoked command. It may be a
  # bare name (bd), or a path ending in /bd (e.g. .../bin/bd).
  first_token="${trimmed%%[[:space:]]*}"
  base="${first_token##*/}"
  [ "$base" = "bd" ] || continue

  # Second token is the bd subcommand (verb).
  rest="${trimmed#"$first_token"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  verb="${rest%%[[:space:]]*}"

  if is_write_verb "$verb" && ! has_actor_flag "$segment"; then
    printf -- '--actor is required inline on every bd write (bd %s ... --actor=<role>)\n' "$verb" >&2
    exit 2
  fi
done < <(split_segments "$command_str")

exit 0
