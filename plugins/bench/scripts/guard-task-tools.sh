#!/usr/bin/env bash
# scripts/guard-task-tools.sh — PreToolUse hook: deny TodoWrite/TaskCreate/TaskUpdate.
#
# This project tracks all work in beads (bd), never in the built-in
# Todo/Task tools (see CLAUDE.md). Wired into hooks.json under PreToolUse
# with matcher "TodoWrite|TaskCreate|TaskUpdate", but the script also checks
# tool_name itself so it is independently testable and never denies
# anything but its exact targets, regardless of matcher wiring.
#
# Input: PreToolUse JSON on stdin (tool_name, tool_input, ...).
# https://code.claude.com/docs/en/hooks#pretooluse-input
#
# Exit 0 = allow (default; also the fail-open path for any parse error).
# Exit 2 = deny; stderr text is surfaced to Claude as the block reason.
set +e

input="$(cat 2>/dev/null)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

case "$tool_name" in
  TodoWrite|TaskCreate|TaskUpdate)
    printf 'this project tracks work in beads - use bd create/update/close\n' >&2
    exit 2
    ;;
esac

exit 0
