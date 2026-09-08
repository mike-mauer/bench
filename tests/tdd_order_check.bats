#!/usr/bin/env bats
# Tests for plugins/bench/scripts/tdd-order-check.sh — the machine check for
# TDD-from-history (docs/factory-protocol.md §7): the first production commit
# in a range must be preceded, in that same range, by a test-only commit.
#
# Each test builds a throwaway git repo under $BATS_TEST_TMPDIR and drives the
# script with a real commit range, mirroring the fixture style in
# claudemd_drift_check.bats and cloud_install.bats.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/tdd-order-check.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git config commit.gpgsign false
  mkdir -p src tests docs
  echo "init" > README.md
  git add README.md
  git commit -qm "chore: init"
  BASE="$(git rev-parse HEAD)"
}

commit_files() { # commit_files <subject> <file>...
  subject="$1"; shift
  for file in "$@"; do
    mkdir -p "$(dirname "$file")"
    printf 'content\n' >> "$file"
    git add "$file"
  done
  git commit -qm "$subject"
}

run_check() { run bash "$SCRIPT" "$@"; }

@test "--help exits 0 and prints usage" {
  run_check --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: tdd-order-check.sh"* ]]
}

@test "missing arguments: usage error, exit 2" {
  run_check
  [ "$status" -eq 2 ]
}

@test "test-then-impl: passes" {
  commit_files "test(#1): pin the bug" "tests/foo_test.py"
  commit_files "feat(#1): fix it" "src/foo.py"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "impl-then-test: fails, naming the offending commit" {
  commit_files "feat(#1): fix it" "src/foo.py"
  bad="$(git rev-parse HEAD)"
  commit_files "test(#1): pin the bug" "tests/foo_test.py"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$bad"* ]]
}

@test "impl-only: fails" {
  commit_files "feat(#1): fix it" "src/foo.py"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 1 ]
}

@test "docs-only range: passes" {
  commit_files "docs: update notes" "docs/notes.md"
  commit_files "docs: readme touchup" "README.md"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "test-only range: passes" {
  commit_files "test(#1): pin the bug" "tests/foo_test.py"
  commit_files "test(#1): pin another bug" "tests/bar_test.py"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "merge commit is ignored" {
  # Explicit, monotonically increasing commit dates make rev-list ordering
  # deterministic across the two branches: the "other" branch's untested
  # production commit is dated earliest, so it must be the one that trips
  # the failure, regardless of which branch HEAD currently sits on.
  git checkout -q -b other "$BASE"
  GIT_AUTHOR_DATE="2026-01-01T00:00:05+00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:05+00:00" \
    commit_files "feat(#2): unrelated production change with no test" "src/bar.py"

  git checkout -q -b side "$BASE"
  GIT_AUTHOR_DATE="2026-01-01T00:00:10+00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:10+00:00" \
    commit_files "test(#1): pin the bug" "tests/foo_test.py"
  GIT_AUTHOR_DATE="2026-01-01T00:00:20+00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:20+00:00" \
    commit_files "feat(#1): fix it" "src/foo.py"

  GIT_AUTHOR_DATE="2026-01-01T00:00:30+00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:30+00:00" \
    git merge -q --no-edit other
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 1 ]
  [[ "$output" != *"Merge branch"* ]]
  [[ "$output" == *"unrelated production change"* ]]
}

@test "a squashed test+impl commit fails (production file with no separate test-only commit)" {
  commit_files "feat(#1): fix it plus its test" "src/foo.py" "tests/foo_test.py"
  head="$(git rev-parse HEAD)"

  run_check "$BASE..$head"
  [ "$status" -eq 1 ]
}

@test "two-argument form is equivalent to the dotted range" {
  commit_files "feat(#1): fix it" "src/foo.py"
  head="$(git rev-parse HEAD)"

  run bash "$SCRIPT" "$BASE" "$head"
  [ "$status" -eq 1 ]
}

@test "single-argument form without .. is a usage error" {
  run_check "not-a-range"
  [ "$status" -eq 2 ]
}
