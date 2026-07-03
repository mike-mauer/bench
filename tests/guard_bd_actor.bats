#!/usr/bin/env bats
# Tests for plugins/bench/scripts/guard-bd-actor.sh (Bench-y4h).
#
# Invariant under test: the PreToolUse hook (matcher: Bash) denies (exit 2)
# any Bash command that invokes a `bd` WRITE verb
# (create|update|close|comment|dep|delete|reopen) without an --actor flag
# present in that same command segment, and allows everything else:
#   - read-only bd commands (list, show, ready, comments, stats, prime, ...)
#   - write verbs that DO carry --actor=x or --actor x
#   - non-bd commands, and near-miss binary names (abd, bdx, command-bd)
#   - path-invoked bd (e.g. ~/.claude/plugins/.../bin/bd) and PATH=... bd
#
# Pure string parsing — the guard must NOT shell out to bd (spec: no bd
# invocation; fast, no network).

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/guard-bd-actor.sh"

payload() {
  # $1 = command string (JSON-escaped by caller)
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":%s}}' "$1"
}

run_guard() {
  # $1 = raw shell command to embed as tool_input.command
  local json_escaped
  json_escaped=$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null) \
    || json_escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "\"%s\"", $0}')
  run bash -c "printf '%s' '$(payload "$json_escaped")' | \"$SCRIPT\""
}

# ---- deny cases ---------------------------------------------------------

@test "bd close X without --actor is denied" {
  run_guard "bd close Bench-1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--actor"* ]]
}

@test "bd update X --status=done without --actor is denied" {
  run_guard "bd update Bench-1 --status=done"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--actor"* ]]
}

@test "bd comment X 'text' without --actor is denied" {
  run_guard "bd comment Bench-1 'hello there'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--actor"* ]]
}

@test "bd dep add without --actor is denied" {
  run_guard "bd dep add Bench-1 Bench-2"
  [ "$status" -eq 2 ]
}

@test "bd delete without --actor is denied" {
  run_guard "bd delete Bench-1"
  [ "$status" -eq 2 ]
}

@test "bd reopen without --actor is denied" {
  run_guard "bd reopen Bench-1"
  [ "$status" -eq 2 ]
}

@test "bd create without --actor is denied" {
  run_guard "bd create --title 'thing'"
  [ "$status" -eq 2 ]
}

@test "chained command: a compliant show followed by a non-compliant close is still denied" {
  run_guard "bd show Bench-1 --actor=engineer && bd close Bench-2"
  [ "$status" -eq 2 ]
}

@test "path-invoked bd write verb without --actor is denied" {
  run_guard "~/.claude/plugins/data/bench-inline/bin/bd close Bench-1"
  [ "$status" -eq 2 ]
}

@test "PATH-prefixed bd write verb without --actor is denied" {
  run_guard "PATH=\$HOME/.claude/plugins/data/bench-inline/bin:\$PATH bd close Bench-1"
  [ "$status" -eq 2 ]
}

# ---- allow cases ---------------------------------------------------------

@test "bd close X --actor=engineer is allowed" {
  run_guard "bd close Bench-1 --actor=engineer"
  [ "$status" -eq 0 ]
}

@test "bd update X --actor engineer (space form) is allowed" {
  run_guard "bd update Bench-1 --status=done --actor engineer"
  [ "$status" -eq 0 ]
}

@test "bd list (read-only) is allowed with no --actor" {
  run_guard "bd list"
  [ "$status" -eq 0 ]
}

@test "bd show (read-only) is allowed with no --actor" {
  run_guard "bd show Bench-1"
  [ "$status" -eq 0 ]
}

@test "bd comments (read-only plural, near-miss of comment) is allowed" {
  run_guard "bd comments Bench-1"
  [ "$status" -eq 0 ]
}

@test "bd ready (read-only) is allowed" {
  run_guard "bd ready"
  [ "$status" -eq 0 ]
}

@test "bd prime (read-only) is allowed" {
  run_guard "bd prime"
  [ "$status" -eq 0 ]
}

@test "bd stats (read-only) is allowed" {
  run_guard "bd stats --json"
  [ "$status" -eq 0 ]
}

@test "non-bd command is allowed" {
  run_guard "git status"
  [ "$status" -eq 0 ]
}

@test "near-miss binary name abd is allowed" {
  run_guard "abd close Bench-1"
  [ "$status" -eq 0 ]
}

@test "near-miss binary name bdx is allowed" {
  run_guard "bdx close Bench-1"
  [ "$status" -eq 0 ]
}

@test "near-miss binary name command-bd is allowed" {
  run_guard "command-bd close Bench-1"
  [ "$status" -eq 0 ]
}

@test "chained command: both segments compliant is allowed" {
  run_guard "bd show Bench-1 --actor=engineer && bd close Bench-2 --actor=engineer"
  [ "$status" -eq 0 ]
}

@test "path-invoked bd write verb WITH --actor is allowed" {
  run_guard "~/.claude/plugins/data/bench-inline/bin/bd close Bench-1 --actor=engineer"
  [ "$status" -eq 0 ]
}

# ---- quote/newline false-deny regressions (reviewer round 1) ------------
#
# Bench-y4h round 1: split_segments split on RAW newlines with no quote
# awareness, so a multi-line quoted argument (commit message body, heredoc
# body) whose interior line begins with a guarded token was sliced into its
# own bare "command segment" and falsely denied — even though the whole
# thing is a single, non-bd (or fully compliant) command. Fix: stop
# splitting on newlines; only split on ;, &&, ||. A real newline-separated
# chain outside any quoting is treated as one segment (a tolerated
# false-allow — the reviewer confirmed false-allows are the acceptable
# trade for a convention guard, false-denies are not).

@test "repro 4: a fully-compliant bd comment whose quoted body contains a bare bd close line is allowed" {
  run_guard 'bd comment Bench-1 --actor=r "line one
bd close Bench-2"'
  [ "$status" -eq 0 ]
}

@test "a git commit whose quoted message body mentions 'bd close X' on its own line is allowed" {
  run_guard 'git commit -m "impl guard
bd close Bench-1 after merge"'
  [ "$status" -eq 0 ]
}

@test "a heredoc body mentioning a bare bd close line is allowed" {
  run_guard 'cat <<EOF
bd close Bench-1
EOF'
  [ "$status" -eq 0 ]
}

@test "control: the same tokens on a single line inside quotes still pass (sanity, not a regression)" {
  run_guard 'bd comment Bench-1 --actor=r "bd close Bench-2 mentioned inline"'
  [ "$status" -eq 0 ]
}

@test "control: a bare single-line bd close with no actor still denies (guard not neutered)" {
  run_guard "bd close Bench-1"
  [ "$status" -eq 2 ]
}

@test "malformed stdin (not JSON) never crashes the hook and does not deny" {
  run bash -c "printf 'not json' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
}

@test "non-Bash tool_name payload is allowed (guard only inspects Bash commands)" {
  run bash -c "printf '{\"tool_name\":\"Edit\",\"tool_input\":{}}' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
}
