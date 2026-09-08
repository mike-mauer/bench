#!/usr/bin/env bats
# Tests for plugins/bench/scripts/human-todos.sh — the SessionStart hook that
# lists the current user's open `human:todo` issues (docs/factory-protocol.md
# §15) so a new session starts with the outstanding asks in view.
#
# `gh` is stubbed on PATH via a fixture script written into $BATS_TEST_TMPDIR
# per test — no real network or GitHub CLI involved. Best-effort hook: every
# case must exit 0, and it must stay silent whenever there is nothing to
# report or `gh` can't be used at all.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/human-todos.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  REAL_PATH="$PATH"
}

# write_gh_stub <auth-exit> <issues-json> — install a `gh` fixture on PATH
# that answers `gh auth status` with the given exit code and `gh issue list
# ...` by printing the given JSON.
write_gh_stub() {
  local auth_exit="$1" issues_json="$2"
  cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
  exit $auth_exit
fi
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  cat <<'JSON'
$issues_json
JSON
  exit 0
fi
exit 1
EOF
  chmod +x "$BIN/gh"
  export PATH="$BIN:$REAL_PATH"
}

@test "no gh on PATH: silent, exit 0" {
  export PATH="/usr/bin:/bin"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh unauthenticated: silent, exit 0" {
  write_gh_stub 1 '[]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "zero to-dos: no output" {
  write_gh_stub 0 '[]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "two to-dos: two lines, each with its blocks parsed" {
  write_gh_stub 0 '[
    {"number": 12, "title": "set ANTHROPIC_API_KEY", "body": "## What I need from you\nadd a secret\n\n## Blocks\n- #34\n"},
    {"number": 13, "title": "create BENCH_ROUTINE_ID", "body": "## What I need from you\nmake a routine\n\n## Blocks\n- #35\n"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 open to-do(s) for you:"* ]]
  [[ "$output" == *"#12 set ANTHROPIC_API_KEY  (blocks #34)"* ]]
  [[ "$output" == *"#13 create BENCH_ROUTINE_ID  (blocks #35)"* ]]
}

@test "body without a Blocks section: no (blocks ...) suffix" {
  write_gh_stub 0 '[
    {"number": 20, "title": "approve access", "body": "## What I need from you\njust a decision, nothing blocked\n"}
  ]'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 open to-do(s) for you:"* ]]
  [[ "$output" == *"#20 approve access"* ]]
  [[ "$output" != *"blocks"* ]]
}
