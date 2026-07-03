#!/usr/bin/env bash
# scripts/guard-checkout.sh — PreToolUse hook (matcher: Bash): deny
# git checkout/switch/restore run from the MAIN worktree while linked
# Worker worktrees (.claude/worktrees/*) exist.
#
# Rationale: the orchestrator's own tree is shared state. A branch change
# there while Workers are mid-flight in linked worktrees can pull the rug
# out from under them (Bench-a40-adjacent hazard class). Guard logic:
#   1. Only fires for git checkout/switch/restore Bash commands.
#   2. Allowed unconditionally inside a LINKED worktree (git-dir differs
#      from git-common-dir) — Workers must never be blocked in their own tree.
#   3. Allowed when .claude/worktrees is absent or has no entries — nothing
#      to protect.
#   4. Escape hatch: BENCH_ALLOW_CHECKOUT=1. Honored both as an env var on
#      the hook process AND as a leading inline assignment in the command
#      string itself, since Claude Code strips leading VAR=value assignments
#      before invoking Bash and the hook process does not inherit them.
#
# Input: PreToolUse JSON on stdin; tool_input.command and cwd.
# https://code.claude.com/docs/en/hooks#pretooluse-input
#
# Exit 0 = allow (default; also the fail-open path for any parse/git error).
# Exit 2 = deny; stderr text is surfaced to Claude as the block reason.
set +e

input="$(cat 2>/dev/null)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
[ "$tool_name" = "Bash" ] || exit 0

command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command_str" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Split on ;, &&, and ||. Deliberately does NOT split on raw newlines: a
# multi-line QUOTED argument (a commit message body, a heredoc body)
# routinely contains lines that start with "git checkout"/"switch"/
# "restore" purely as prose — e.g. `git commit -m "fix parser\ngit checkout
# was mishandled"` or a heredoc body mentioning "git checkout" in its text.
# Splitting on bare newlines without quote/heredoc awareness turns that
# prose into its own bogus "command segment" and falsely denies a command
# that never actually invokes checkout/switch/restore (Bench-y4h round 1).
# The trade-off: a real newline-separated command chain outside of any
# quoting is now treated as a single segment; false-allow is the tolerable
# direction for this guard, false-deny (blocking legitimate work) is not.
split_git_segments() {
  # NUL-delimited, not newline-delimited: `read` terminates a field on ANY
  # newline byte, so routing separators through \n can never coexist with
  # preserving a real newline that occurs INSIDE a segment (a quoted
  # commit-message body, a heredoc body). NUL cannot appear in a shell
  # command string, so it's a safe, unambiguous delimiter. The trailing ';'
  # guarantees the final segment is itself NUL-terminated — `read -d ''`
  # drops an unterminated final field otherwise.
  printf '%s;' "$1" | sed -E 's/&&|\|\|/;/g' | tr ';' '\000'
}

# Escape hatch, hook-process env.
[ "${BENCH_ALLOW_CHECKOUT:-}" = "1" ] && exit 0

# Escape hatch, inline command-string form: a leading VAR=value assignment
# that Claude Code strips before spawning Bash, so the hook process itself
# never sees it as an env var — grep the raw command string instead.
if printf '%s' "$command_str" | grep -Eq '(^|[[:space:];&|]) *BENCH_ALLOW_CHECKOUT=1([[:space:]]|$)'; then
  exit 0
fi

# Determine whether any command segment actually INVOKES git with a
# checkout/switch/restore subcommand — not merely a string that mentions
# those words (e.g. `git commit -m "block git checkout"`, `echo "git switch"`).
# Split on ;, &&, ||, and newlines, then per segment: the first token must
# be `git` (or a path ending in /git), and the first non-option token after
# it (skipping simple `git -C <dir>` / `--flag[=value]` forms) must be one
# of checkout/switch/restore.
command_invokes_checkout=0
while IFS= read -r -d '' segment; do
  [ -n "$segment" ] || continue

  # Strip leading VAR=value assignments.
  trimmed="$segment"
  while [[ "$trimmed" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
    trimmed="${BASH_REMATCH[1]}"
  done
  trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"

  first_token="${trimmed%%[[:space:]]*}"
  base="${first_token##*/}"
  [ "$base" = "git" ] || continue

  rest="${trimmed#"$first_token"}"
  # Walk remaining tokens, skipping option flags and their values (e.g.
  # `-C dir`, `--git-dir=x`), to find git's subcommand.
  subcommand=""
  while [ -n "$rest" ]; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [ -n "$rest" ] || break
    tok="${rest%%[[:space:]]*}"
    rest="${rest#"$tok"}"
    case "$tok" in
      -C)
        # -C takes a value as the next token; skip it too.
        rest="${rest#"${rest%%[![:space:]]*}"}"
        val="${rest%%[[:space:]]*}"
        rest="${rest#"$val"}"
        continue
        ;;
      -*)
        continue
        ;;
      *)
        subcommand="$tok"
        break
        ;;
    esac
  done

  case "$subcommand" in
    checkout|switch|restore) command_invokes_checkout=1; break ;;
  esac
done < <(split_git_segments "$command_str")

[ "$command_invokes_checkout" -eq 1 ] || exit 0

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

git_dir="$(git rev-parse --git-dir 2>/dev/null)"
git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
git_dir_real="$(cd "$git_dir" 2>/dev/null && pwd -P 2>/dev/null || echo "$git_dir")"
git_common_dir_real="$(cd "$git_common_dir" 2>/dev/null && pwd -P 2>/dev/null || echo "$git_common_dir")"

# Linked worktree (git-dir != git-common-dir): always allowed.
[ "$git_dir_real" = "$git_common_dir_real" ] || exit 0

# Main tree: only deny if .claude/worktrees has entries.
toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$toplevel" ] || exit 0
wt_dir="$toplevel/.claude/worktrees"
[ -d "$wt_dir" ] || exit 0
if [ -z "$(find "$wt_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  exit 0
fi

printf 'git checkout/switch/restore is blocked in the main worktree while linked worktrees exist under .claude/worktrees (would affect shared state Workers depend on). Run this inside the specific worktree instead, or set BENCH_ALLOW_CHECKOUT=1 to override.\n' >&2
exit 2
