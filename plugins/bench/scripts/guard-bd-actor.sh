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

# A command may chain multiple invocations with &&, ||, ;, or newlines.
# Evaluate each segment independently: a compliant `bd show ... --actor=x`
# must not shield a later non-compliant `bd close ...` in the same command.
# This is a best-effort lexical split (adequate for the shapes agents emit:
# straightforward chaining, not deliberately obfuscated shell).
split_segments() {
  # Trailing newline is required: some bash/read implementations (notably
  # bash 3.2, macOS's default /bin/bash) silently drop the final line of a
  # `read` loop fed by process substitution when the producer's output
  # doesn't end in \n.
  printf '%s\n' "$1" | tr ';\n' '\n\n' | sed -E 's/&&|\|\|/\n/g'
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

while IFS= read -r segment; do
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
