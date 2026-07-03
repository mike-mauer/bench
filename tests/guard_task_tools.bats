#!/usr/bin/env bats
# Tests for plugins/bench/scripts/guard-task-tools.sh (Bench-y4h).
#
# Invariant under test: the PreToolUse hook denies (exit 2, message on
# stderr) TodoWrite/TaskCreate/TaskUpdate tool calls, telling the caller to
# use bd instead — and passes through (exit 0, silent) every other tool.
#
# The hook receives the PreToolUse JSON payload on stdin
# (https://code.claude.com/docs/en/hooks#pretooluse-input): a top-level
# `tool_name` field plus a `tool_input` object whose shape depends on the
# tool. This guard only inspects `tool_name`.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/guard-task-tools.sh"

payload() {
  # $1 = tool_name
  printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{}}' "$1"
}

@test "TodoWrite is denied with the bd-redirect message" {
  run bash -c "printf '%s' '$(payload TodoWrite)' | \"$SCRIPT\""
  [ "$status" -eq 2 ]
  [[ "$output" == *"beads"* ]]
  [[ "$output" == *"bd create"* || "$output" == *"bd update"* || "$output" == *"bd"* ]]
}

@test "TaskCreate is denied with the bd-redirect message" {
  run bash -c "printf '%s' '$(payload TaskCreate)' | \"$SCRIPT\""
  [ "$status" -eq 2 ]
  [[ "$output" == *"beads"* ]]
}

@test "TaskUpdate is denied with the bd-redirect message" {
  run bash -c "printf '%s' '$(payload TaskUpdate)' | \"$SCRIPT\""
  [ "$status" -eq 2 ]
  [[ "$output" == *"beads"* ]]
}

@test "Bash tool calls pass through untouched" {
  run bash -c "printf '%s' '$(payload Bash)' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Edit tool calls pass through untouched" {
  run bash -c "printf '%s' '$(payload Edit)' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a tool named TodoWriteExtra (not an exact match) passes through" {
  run bash -c "printf '%s' '$(payload TodoWriteExtra)' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed stdin (not JSON) never crashes the hook and does not deny" {
  run bash -c "printf 'not json' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
}
