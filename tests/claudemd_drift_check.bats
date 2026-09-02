#!/usr/bin/env bats
# Tests for plugins/bench/scripts/claudemd-drift-check.sh — the SessionStart hook
# that warns when the project's managed CLAUDE.md block is stale relative to the
# template the plugin ships.
#
# The regression these pin down: the marker match must be anchored to the start of
# a line. A CLAUDE.md that merely DOCUMENTS the marker in prose (as this repo's own
# does, inside backticks mid-sentence) matched the unanchored pattern first and
# yielded an EMPTY hash — so `[ -n "$have" ]` was false and a genuinely stale block
# was never reported. Silent, and exactly on the file the hook exists to watch.
#
# Read-only hook: it must never edit CLAUDE.md and must always exit 0.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/claudemd-drift-check.sh"
PLUGIN_ROOT="$BATS_TEST_DIRNAME/../plugins/bench"
TEMPLATE="$PLUGIN_ROOT/templates/CLAUDE.bench.md"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export CLAUDE_PROJECT_DIR="$PROJ"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  WANT="$(bash "$PLUGIN_ROOT/scripts/bench-hash.sh" "$TEMPLATE")"
}

write_claudemd() { # write_claudemd <hash> [prose-mention]
  {
    printf '# Proj\n\n'
    [ -n "${2:-}" ] && printf -- '- the block is marked `<!-- BEGIN BENCH v:N hash:XXXX -->` and managed by `/bench:init`.\n\n'
    printf '<!-- BEGIN BENCH v:1 hash:%s -->\nrules\n<!-- END BENCH -->\n' "$1"
  } > "$PROJ/CLAUDE.md"
}

@test "current block: no warning, exit 0" {
  write_claudemd "$WANT"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stale block: warns with both hashes" {
  write_claudemd "deadbeef"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"deadbeef"* ]]
  [[ "$output" == *"$WANT"* ]]
}

@test "stale block is still reported when the file also mentions the marker in prose" {
  write_claudemd "deadbeef" with-prose
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"deadbeef"* ]]
}

@test "a prose mention alone is not treated as an installed block" {
  printf '# Proj\n\nwe use `<!-- BEGIN BENCH v:N hash:XXXX -->` markers.\n' > "$PROJ/CLAUDE.md"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Bench block found"* ]]
}

@test "missing CLAUDE.md: reports the absent block, exits 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Bench block found"* ]]
}

@test "never edits CLAUDE.md" {
  write_claudemd "deadbeef" with-prose
  before="$(cat "$PROJ/CLAUDE.md")"
  run bash "$SCRIPT"
  [ "$(cat "$PROJ/CLAUDE.md")" = "$before" ]
}
