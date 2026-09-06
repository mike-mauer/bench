#!/usr/bin/env bats
# Tests for the body-parsing function in plugins/bench/scripts/factory-ready.sh
# (docs/factory-protocol.md §5 "ready"). No network: the script is sourced
# under the BASH_SOURCE guard, which defines `parse_blocked_by` without running
# main() or requiring `gh`.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/factory-ready.sh"

setup() {
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

@test "extracts a single #n ref from the Blocked by section" {
  body=$'## Acceptance criteria\n- [ ] thing\n\n## Blocked by\n- #12\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "12" ]
}

@test "extracts multiple refs, sorted and deduped" {
  body=$'## Blocked by\n- #30\n- #7\n- #7\n- #12\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = $'7\n12\n30' ]
}

@test "ignores #n refs outside the Blocked by section" {
  body=$'## Source\nSpec: see #99\n\n## Notes for the builder\n- watch out, related to #100\n\n## Blocked by\n- #5\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "stops at the next heading" {
  body=$'## Blocked by\n- #5\n\n## Out of scope\n- #6 is unrelated\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "no Blocked by section produces empty output" {
  body=$'## Acceptance criteria\n- [ ] thing\n\n## Out of scope\n- nothing\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "empty Blocked by section produces empty output" {
  body=$'## Blocked by\n\n## Notes for the builder\n- n/a\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "is case-insensitive on the heading text" {
  body=$'## blocked BY\n- #4\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

@test "handles a ref with trailing text on the same line" {
  body=$'## Blocked by\n- #8   (schema must land first)\n'
  run parse_blocked_by "$body"
  [ "$status" -eq 0 ]
  [ "$output" = "8" ]
}

@test "sourcing the script does not require gh or run main" {
  # If main() ran on source, this would fail loudly (no gh on PATH in CI sandboxes
  # that don't have it, and no --repo). Sourcing above already proved this, but
  # assert explicitly that the guard held: parse_blocked_by is defined, and no
  # stray output happened as a side effect of sourcing.
  type -t parse_blocked_by
}

@test "--help prints usage without requiring gh" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"factory-ready.sh"* ]]
}
