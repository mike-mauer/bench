#!/usr/bin/env bats
# Tests for plugins/bench/scripts/cloud-install.sh — the curl-able Bench v2
# installer for a project that never had Bench and has no Claude CLI.
#
# The contract under test:
#   • the four built-in agents (planner/engineer/qa/reviewer) always land in
#     .claude/agents/, overwritten on re-run (plugin-owned);
#   • --with installs an optional role only if the project doesn't already
#     have a copy (never clobbers a customization);
#   • .claude/skills/bench-orchestrator/SKILL.md is installed, overwritten on
#     re-run — the managed CLAUDE.md block requires it, so it fails the
#     install like a missing agent when it can't be written;
#   • .claude/workflows/factory.js is installed, overwritten on re-run;
#   • .claude/scripts/{factory-ready,gh-issue-dep,tdd-order-check}.sh are
#     installed and left executable;
#   • CLAUDE.md gets the `<!-- BEGIN BENCH v:2 hash:XXXX -->` block, hash from
#     the canonical bench-hash.sh, refreshed in place on a stale re-run, and
#     left alone with a BEGIN-but-no-END marker;
#   • --dispatch installs the matching template, but never overwrites an
#     existing .github/workflows/factory-dispatch.yml;
#   • --dry-run writes nothing;
#   • it never runs git commit, never touches .claude/settings.json;
#   • exit 1 when the agents or the skill could not be written.
#
# Hermetic: BENCH_SOURCE_DIR points at this checkout's plugins/bench, so
# nothing is fetched over the network.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/cloud-install.sh"
PLUGIN_ROOT="$BATS_TEST_DIRNAME/../plugins/bench"
HASHER="$PLUGIN_ROOT/scripts/bench-hash.sh"
TEMPLATE="$PLUGIN_ROOT/templates/CLAUDE.bench.md"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  export BENCH_SOURCE_DIR="$PLUGIN_ROOT"
}

run_install() { run bash "$SCRIPT" --project-dir "$PROJ" "$@"; }

@test "fresh project: installs the four built-in agents" {
  run_install
  [ "$status" -eq 0 ]
  for role in planner engineer qa reviewer; do
    [ -f "$PROJ/.claude/agents/$role.md" ]
  done
}

@test "fresh project: installs the factory workflow" {
  run_install
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/workflows/factory.js" ]
  diff -q "$PROJ/.claude/workflows/factory.js" "$PLUGIN_ROOT/workflows/factory.js"
}

@test "fresh project: installs the bench-orchestrator skill" {
  run_install
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/skills/bench-orchestrator/SKILL.md" ]
  diff -q "$PROJ/.claude/skills/bench-orchestrator/SKILL.md" \
    "$PLUGIN_ROOT/skills/bench-orchestrator/SKILL.md"
}

@test "fresh project: installs the scripts, executable" {
  run_install
  [ "$status" -eq 0 ]
  for s in factory-ready.sh gh-issue-dep.sh tdd-order-check.sh; do
    [ -f "$PROJ/.claude/scripts/$s" ]
    [ -x "$PROJ/.claude/scripts/$s" ]
    diff -q "$PROJ/.claude/scripts/$s" "$PLUGIN_ROOT/scripts/$s"
  done
}

@test "re-run: skill and scripts overwritten" {
  run_install
  [ "$status" -eq 0 ]
  echo "MUTATED" >> "$PROJ/.claude/skills/bench-orchestrator/SKILL.md"
  echo "MUTATED" >> "$PROJ/.claude/scripts/factory-ready.sh"

  run_install

  [ "$status" -eq 0 ]
  ! grep -q MUTATED "$PROJ/.claude/skills/bench-orchestrator/SKILL.md"
  ! grep -q MUTATED "$PROJ/.claude/scripts/factory-ready.sh"
  [ -x "$PROJ/.claude/scripts/factory-ready.sh" ]
}

@test "a missing skill fails the install like a missing agent" {
  broken="$BATS_TEST_TMPDIR/broken-plugin"
  mkdir -p "$broken"
  cp -r "$PLUGIN_ROOT/agents" "$broken/agents"
  mkdir -p "$broken/skills"
  # skills/bench-orchestrator/SKILL.md deliberately missing

  run env BENCH_SOURCE_DIR="$broken" bash "$SCRIPT" --project-dir "$PROJ"

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not write one or more of"* ]]
  [[ "$output" == *"bench-orchestrator skill"* ]]
  [ -f "$PROJ/.claude/agents/planner.md" ]
  [ ! -f "$PROJ/.claude/skills/bench-orchestrator/SKILL.md" ]
}

@test "fresh project: CLAUDE.md gets the v2 block with the canonical hash" {
  run_install
  [ "$status" -eq 0 ]

  want="$(bash "$HASHER" "$TEMPLATE")"
  have="$(grep -o 'BEGIN BENCH v:2 hash:[0-9a-f]*' "$PROJ/CLAUDE.md" | head -1 | grep -o '[0-9a-f]*$')"
  [ -n "$want" ]
  [ "$have" = "$want" ]
  grep -q '<!-- END BENCH -->' "$PROJ/CLAUDE.md"
  grep -q 'Bench harness — operating rules' "$PROJ/CLAUDE.md"
}

@test "re-run: agents and workflow overwritten, no duplicate CLAUDE.md block" {
  run_install
  [ "$status" -eq 0 ]
  echo "MUTATED" >> "$PROJ/.claude/agents/planner.md"

  run_install

  [ "$status" -eq 0 ]
  ! grep -q MUTATED "$PROJ/.claude/agents/planner.md"
  [[ "$output" == *"already current"* ]]
  [ "$(grep -c 'BEGIN BENCH' "$PROJ/CLAUDE.md")" -eq 1 ]
}

@test "--with installs an optional role; an unknown role warns without failing" {
  run_install --with data-eng,nope

  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/agents/data-eng.md" ]
  [[ "$output" == *"unknown or unavailable role 'nope'"* ]]
}

@test "--with does not overwrite a role the project already customized" {
  mkdir -p "$PROJ/.claude/agents"
  echo 'my customized data-eng' > "$PROJ/.claude/agents/data-eng.md"

  run_install --with data-eng

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.claude/agents/data-eng.md")" = "my customized data-eng" ]
  [[ "$output" == *"already installed"* ]]
}

@test "a stale CLAUDE.md block is refreshed in place, other content survives" {
  want="$(bash "$HASHER" "$TEMPLATE")"
  {
    printf '# My Project\n\nsome project rules\n\n'
    printf '<!-- BEGIN BENCH v:2 hash:deadbeef -->\nOLD BENCH RULES\n<!-- END BENCH -->\n'
  } > "$PROJ/CLAUDE.md"

  run_install

  [ "$status" -eq 0 ]
  [ "$(grep -c 'BEGIN BENCH' "$PROJ/CLAUDE.md")" -eq 1 ]
  grep -q "hash:$want" "$PROJ/CLAUDE.md"
  ! grep -q 'OLD BENCH RULES' "$PROJ/CLAUDE.md"
  grep -q 'some project rules' "$PROJ/CLAUDE.md"
}

@test "a CLAUDE.md with BEGIN but no END marker is left untouched" {
  printf '# Proj\n<!-- BEGIN BENCH v:2 hash:aaaa -->\nhalf a block\n' > "$PROJ/CLAUDE.md"
  before="$(cat "$PROJ/CLAUDE.md")"

  run_install

  [[ "$output" == *"no END BENCH"* ]]
  [ "$(cat "$PROJ/CLAUDE.md")" = "$before" ]
}

@test "--dispatch action installs the action dispatch template" {
  run_install --dispatch action

  [ "$status" -eq 0 ]
  [ -f "$PROJ/.github/workflows/factory-dispatch.yml" ]
  grep -q 'claude-code-action' "$PROJ/.github/workflows/factory-dispatch.yml"
}

@test "--dispatch routine installs the routine dispatch template" {
  run_install --dispatch routine

  [ "$status" -eq 0 ]
  grep -q 'BENCH_ROUTINE_ID' "$PROJ/.github/workflows/factory-dispatch.yml"
}

@test "--dispatch never overwrites an existing dispatch workflow" {
  mkdir -p "$PROJ/.github/workflows"
  echo 'my custom dispatch' > "$PROJ/.github/workflows/factory-dispatch.yml"

  run_install --dispatch action

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.github/workflows/factory-dispatch.yml")" = "my custom dispatch" ]
  [[ "$output" == *"already exists"* ]]
}

@test "an invalid --dispatch value fails fast" {
  run_install --dispatch nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"--dispatch must be action or routine"* ]]
  [ ! -e "$PROJ/.claude" ]
}

@test "--dry-run writes nothing at all" {
  run_install --dry-run --with data-eng --dispatch action

  [ "$status" -eq 0 ]
  [[ "$output" == *"would write .claude/agents/planner.md"* ]]
  [ "$(find "$PROJ" -mindepth 1 | wc -l)" -eq 0 ]
}

@test "never touches .claude/settings.json" {
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.claude/settings.json" ]
}

@test "never runs git commit: project dir stays untouched by git" {
  ( cd "$PROJ" && git init -q )
  run_install
  [ "$status" -eq 0 ]
  run git -C "$PROJ" log
  [[ "$output" == *"does not have any commits yet"* ]]
}

@test "a fork can be installed from: BENCH_REPO is irrelevant when BENCH_SOURCE_DIR is set, but still accepted" {
  run env BENCH_REPO=acme/bench-fork BENCH_SOURCE_DIR="$PLUGIN_ROOT" bash "$SCRIPT" --project-dir "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/agents/planner.md" ]
}

@test "--help exits 0 and documents the curl one-liner" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"curl -fsSL"* ]]
  [[ "$output" == *"cloud-install.sh"* ]]
}

@test "an unknown option fails instead of silently installing" {
  run bash "$SCRIPT" --project-dir "$PROJ" --frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
  [ ! -e "$PROJ/.claude" ]
}

@test "BENCH_SOURCE_DIR pointed at a directory missing an agent fails with exit 1" {
  broken="$BATS_TEST_TMPDIR/broken-plugin"
  mkdir -p "$broken/agents"
  cp "$PLUGIN_ROOT/agents/engineer.md" "$broken/agents/engineer.md"
  cp "$PLUGIN_ROOT/agents/qa.md" "$broken/agents/qa.md"
  cp "$PLUGIN_ROOT/agents/reviewer.md" "$broken/agents/reviewer.md"
  # planner.md deliberately missing

  run env BENCH_SOURCE_DIR="$broken" bash "$SCRIPT" --project-dir "$PROJ"

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not write one or more of"* ]]
  [ -f "$PROJ/.claude/agents/engineer.md" ]
  [ ! -f "$PROJ/.claude/agents/planner.md" ]
}
