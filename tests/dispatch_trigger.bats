#!/usr/bin/env bats
# Tests the dispatch trigger label (#33).
#
# `bench:ready` used to do two jobs: §5 eligibility (planner-owned, durable) AND the
# `labeled` event that starts a run. That conflation double-built every sub-issue of
# an epic — the planner labels children `bench:ready` during the Plan phase, each
# label event fired a dispatch lane, and the parent's runWaves then dispatched the
# same children itself.
#
# `bench:dispatch` now owns the trigger. The planner never applies it, so nothing the
# harness does can start a run; an epic's children are dispatched only by their
# parent. Static source checks, the same approach as cloud_install.bats' nounset
# guard test — these files are consumed by GitHub Actions and the Workflow runtime,
# neither of which is executable from bats.

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/bench"
TEMPLATES="$PLUGIN/templates/bench-dispatch-action.yml $PLUGIN/templates/bench-dispatch-routine.yml"

@test "both dispatch lanes fire on bench:dispatch, not bench:ready" {
  for f in $TEMPLATES; do
    run grep -c "github.event.label.name == 'bench:dispatch'" "$f"
    [ "$status" -eq 0 ] || { echo "FAIL $(basename "$f"): no bench:dispatch guard" >&2; false; }
  done
}

@test "no dispatch lane is still triggered by bench:ready" {
  for f in $TEMPLATES; do
    if grep -q "label.name == 'bench:ready'" "$f"; then
      echo "FAIL $(basename "$f") still fires on bench:ready — the harness sets that label" >&2
      false
    fi
  done
}

@test "claim() strips the trigger label, making it one-shot" {
  run grep -c 'bench:dispatch' "$PLUGIN/workflows/factory.js"
  [ "$status" -eq 0 ] || { echo "FAIL factory.js never mentions bench:dispatch" >&2; false; }
  # the instruction must live in claim(), not just anywhere in the file
  run bash -c "sed -n '/^async function claim(/,/^}/p' '$PLUGIN/workflows/factory.js' | grep -c 'bench:dispatch'"
  [ "$output" -ge 1 ] || { echo "FAIL claim() does not remove bench:dispatch" >&2; false; }
}

@test "the planner is told to set bench:ready but never bench:dispatch" {
  run grep -c 'bench:dispatch' "$PLUGIN/agents/planner.md"
  [ "$status" -eq 0 ] || { echo "FAIL planner.md says nothing about bench:dispatch" >&2; false; }
}

@test "/bench:init creates the bench:dispatch label" {
  run grep -c 'bench:dispatch' "$PLUGIN/commands/init.md"
  [ "$status" -eq 0 ] || { echo "FAIL init.md never creates bench:dispatch" >&2; false; }
}

@test "/bench:doctor checks for the bench:dispatch label" {
  run grep -c 'bench:dispatch' "$PLUGIN/commands/doctor.md"
  [ "$status" -eq 0 ] || { echo "FAIL doctor.md does not check bench:dispatch" >&2; false; }
}

@test "the protocol documents bench:dispatch in its label table" {
  run grep -c 'bench:dispatch' "$PLUGIN/docs/protocol.md"
  [ "$status" -eq 0 ] || { echo "FAIL protocol.md does not document bench:dispatch" >&2; false; }
}
