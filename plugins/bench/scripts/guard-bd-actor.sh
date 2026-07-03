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

# --- Round 3 redesign (Bench-y4h round 3, human-authorized) ---------------
#
# Rounds 1 and 2 both tried to make the SEPARATOR SCAN quote-aware after
# the fact (first by excluding newlines, then by NUL-delimiting) and both
# left a real hole: any separator that appears literally inside a quoted
# argument (a commit-message body, a bd comment body) still reached the
# splitter and was treated as a command boundary, falsely denying a single,
# often fully-compliant command.
#
# The fix operates one step earlier: BEFORE any segment-splitting, delete
# the CONTENTS of every quoted span (single- or double-quoted) from the
# command string, via a character-scan state machine. Structure survives
# (opening/closing quote chars are removed, the string collapses around
# them) but nothing inside a quote — semicolons, &&, ||, bare guarded
# verbs, guarded-looking prose — can ever reach the splitter or the verb
# detector, because it no longer exists in the string being scanned.
#
# Fail-open principle: if the command string ends INSIDE an unterminated
# quote, the state machine is by definition uncertain about the command's
# real structure. Per the human-authorized round-3 spec, uncertainty always
# fails open (exit 0) with a one-line stderr warning — never denies. A
# false-allow on a malformed/truncated command is an acceptable miss for a
# convention guard; a false-deny is not.
_STRIPPED=""
strip_quoted_spans() {
  # $1 = raw command string. Sets the global _STRIPPED to the string with
  # quoted-span CONTENTS deleted (structure-preserving). Returns 0 if every
  # quote opened was also closed; returns 1 if the scan ends mid-quote.
  # Single quotes take no escapes (shell-correct: '\' has no special
  # meaning inside '...'). Inside double quotes, a backslash escapes the
  # next character (so \" does not close the span), matching shell
  # double-quote semantics closely enough for this lexical guard.
  local s="$1" out="" i c n="${#1}" state=U
  for (( i = 0; i < n; i++ )); do
    c="${s:i:1}"
    case "$state" in
      U)
        case "$c" in
          \') state=S ;;
          \") state=D ;;
          *) out+="$c" ;;
        esac
        ;;
      S)
        [ "$c" = "'" ] && state=U
        ;;
      D)
        case "$c" in
          \") state=U ;;
          \\) i=$((i + 1)) ;;
          *) : ;;
        esac
        ;;
    esac
  done
  _STRIPPED="$out"
  [ "$state" = "U" ]
}

# NOTE: `local x=$(...)` masks the command substitution's exit status with
# `local`'s own (always 0). Assign in two steps so $? reflects the scan.
strip_quoted_spans "$command_str"
quote_scan_ok=$?
stripped_command="$_STRIPPED"

if [ "$quote_scan_ok" -ne 0 ]; then
  printf 'guard-bd-actor: unterminated quote in command — allowing (fail-open; could not reliably scan for bd write verbs)\n' >&2
  exit 0
fi

# A command may chain multiple invocations with &&, ||, or ;, evaluated on
# the QUOTE-STRIPPED string only, so a separator inside a quoted argument
# can never be mistaken for a real command boundary. Evaluate each segment
# independently: a compliant `bd show ... --actor=x` must not shield a
# later non-compliant `bd close ...` in the same command.
#
# Deliberately does NOT split on raw newlines — a real, entirely unquoted
# newline-separated chain (`bd show X --actor=e` then a literal newline
# then `bd close Y`) is treated as a single segment and allowed if ANY
# --actor appears in it. False-allow is the tolerable direction for this
# convention guard; false-deny (blocking legitimate work) is not — this
# was the explicit framing from reviewer round 1, reaffirmed in round 3.
split_segments() {
  # NUL-delimited, not newline-delimited: `read` terminates a field on ANY
  # newline byte, so routing separators through \n can never coexist with
  # preserving a real newline that occurs INSIDE a segment (now only
  # possible for an unquoted heredoc body, since quoted spans are already
  # stripped above). NUL cannot appear in a shell command string, so it's a
  # safe, unambiguous delimiter. The trailing ';' guarantees the final
  # segment is itself NUL-terminated — `read -d ''` drops an unterminated
  # final field otherwise.
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
done < <(split_segments "$stripped_command")

exit 0
