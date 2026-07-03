#!/usr/bin/env bats
# Tests for plugins/bench/scripts/guard-checkout.sh (Bench-y4h).
#
# Invariant under test: the PreToolUse hook (matcher: Bash) denies
# `git checkout|switch|restore` when CWD resolves to the MAIN worktree
# (git-dir == git-common-dir) AND .claude/worktrees has entries (i.e. Worker
# trees exist that could be orphaned/confused by a branch change underneath
# them) — and allows it:
#   - inside a linked worktree (git-dir != git-common-dir), regardless of
#     .claude/worktrees contents
#   - in the main tree when .claude/worktrees is absent/empty
#   - anywhere, when BENCH_ALLOW_CHECKOUT=1 is set — either as an env var on
#     the hook process, or as a leading inline assignment in the command
#     string itself (Claude Code strips leading VAR=value assignments before
#     invoking Bash, so the hook process does NOT inherit an inline
#     `BENCH_ALLOW_CHECKOUT=1 git checkout ...`; the guard must also grep the
#     command string for the escape hatch to honor the inline form)
#   - non-checkout git commands, and other tools entirely
#
# Fixture: a throwaway git repo with a linked worktree, mirroring the
# git-dir/git-common-dir realpath normalization used in beads-stop-guard.sh.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/guard-checkout.sh"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@test.invalid"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@test.invalid"

  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  echo "bench" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "initial"

  unset BENCH_ALLOW_CHECKOUT
}

add_worktree_entry() {
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" branch other-branch >/dev/null 2>&1
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/agent-test" other-branch
}

payload() {
  # $1 = command string, $2 = cwd
  printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" "$1"
}

run_guard_in() {
  # $1 = cwd, $2 = command
  run bash -c "cd \"$1\" && printf '%s' '$(payload "$2" "$1")' | \"$SCRIPT\""
}

# JSON-safe variant for command strings containing quotes/special chars
# (e.g. a commit message). Builds the payload with jq instead of naive
# printf substitution.
run_guard_in_safe() {
  # $1 = cwd, $2 = command
  local json
  json="$(jq -n --arg cwd "$1" --arg cmd "$2" \
    '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Bash",tool_input:{command:$cmd}}')"
  run bash -c "cd \"$1\" && printf '%s' '$json' | \"$SCRIPT\""
}

@test "checkout denied in main tree when worktrees exist" {
  add_worktree_entry
  run_guard_in "$REPO" "git checkout other-branch"
  [ "$status" -eq 2 ]
  [[ "$output" == *"worktree"* || "$output" == *"checkout"* ]]
}

@test "switch denied in main tree when worktrees exist" {
  add_worktree_entry
  run_guard_in "$REPO" "git switch other-branch"
  [ "$status" -eq 2 ]
}

@test "restore denied in main tree when worktrees exist" {
  add_worktree_entry
  run_guard_in "$REPO" "git restore ."
  [ "$status" -eq 2 ]
}

@test "checkout allowed inside a linked worktree" {
  add_worktree_entry
  run_guard_in "$REPO/.claude/worktrees/agent-test" "git checkout main"
  [ "$status" -eq 0 ]
}

@test "checkout allowed in main tree when no worktrees dir exists" {
  run_guard_in "$REPO" "git checkout other-branch"
  [ "$status" -eq 0 ]
}

@test "checkout allowed in main tree when worktrees dir exists but is empty" {
  mkdir -p "$REPO/.claude/worktrees"
  run_guard_in "$REPO" "git checkout other-branch"
  [ "$status" -eq 0 ]
}

@test "escape hatch via inline BENCH_ALLOW_CHECKOUT=1 prefix in the command string is allowed" {
  add_worktree_entry
  run_guard_in "$REPO" "BENCH_ALLOW_CHECKOUT=1 git checkout other-branch"
  [ "$status" -eq 0 ]
}

@test "escape hatch via hook-process env var is allowed" {
  add_worktree_entry
  export BENCH_ALLOW_CHECKOUT=1
  run_guard_in "$REPO" "git checkout other-branch"
  [ "$status" -eq 0 ]
  unset BENCH_ALLOW_CHECKOUT
}

@test "non-checkout git command is allowed" {
  add_worktree_entry
  run_guard_in "$REPO" "git status"
  [ "$status" -eq 0 ]
}

@test "non-Bash tool call is allowed" {
  run bash -c "printf '{\"tool_name\":\"Edit\",\"tool_input\":{}}' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
}

@test "malformed stdin (not JSON) never crashes the hook and does not deny" {
  run bash -c "printf 'not json' | \"$SCRIPT\""
  [ "$status" -eq 0 ]
}

@test "a word that merely contains checkout, like git-checkout-helper, is not falsely matched" {
  add_worktree_entry
  run_guard_in "$REPO" "git-checkout-helper other-branch"
  [ "$status" -eq 0 ]
}

@test "a commit message that merely mentions 'git checkout' is not falsely denied" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'git commit -m "add guard to block git checkout in main tree"'
  [ "$status" -eq 0 ]
}

@test "an echo that merely mentions 'git switch' is not falsely denied" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'echo "use git switch instead"'
  [ "$status" -eq 0 ]
}

@test "git -C <dir> checkout is still recognized as a real checkout invocation" {
  add_worktree_entry
  run_guard_in "$REPO" "git -C $REPO checkout other-branch"
  [ "$status" -eq 2 ]
}

# ---- quote/newline false-deny regressions (reviewer round 1) ------------
#
# Bench-y4h round 1: split_git_segments split on RAW newlines with no quote
# awareness, so a multi-line quoted commit-message body or heredoc body
# whose interior line begins with a guarded token was sliced into its own
# bare "command segment" and falsely denied, even though the real, single
# command (git commit / cat heredoc) never invokes checkout/switch/restore.
# Fix: stop splitting on newlines; only split on ;, &&, ||.

@test "repro 2: a git commit whose quoted message body mentions 'git checkout' on its own line is allowed" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'git commit -m "fix parser
git checkout was mishandled"'
  [ "$status" -eq 0 ]
}

@test "repro 3: a heredoc body mentioning a bare 'git checkout' line is allowed" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'cat <<EOF
git checkout notes here
EOF'
  [ "$status" -eq 0 ]
}

@test "control: a bare single-line git checkout with worktrees present still denies (guard not neutered)" {
  add_worktree_entry
  run_guard_in "$REPO" "git checkout other-branch"
  [ "$status" -eq 2 ]
}

# ---- round 2: ;/&&/|| INSIDE quotes still falsely denied ----------------
#
# Bench-y4h round 2: the round-1 fix stopped splitting on raw newlines but
# still split on ;, &&, || with no quote awareness, so a ;/&&/|| appearing
# INSIDE a quoted argument, immediately followed by a guarded token, was
# still sliced into a bogus segment and falsely denied. Round-3 redesign:
# strip quoted-span CONTENTS with a char-scan state machine BEFORE
# splitting, so separators inside quotes never reach the splitter.

@test "round2: a git commit message with a semicolon+git-checkout inside its quoted body is allowed" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'git commit -m "parser fixed; git checkout now works"'
  [ "$status" -eq 0 ]
}

@test "round2: a git commit message with && + git-checkout inside its quoted body is allowed" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'git commit -m "do this && git checkout foo"'
  [ "$status" -eq 0 ]
}

# ---- round 3: fail-open on unterminated quote ----------------------------

@test "round3: an unterminated quote fails open (exit 0) and warns on stderr" {
  add_worktree_entry
  run_guard_in_safe "$REPO" 'git commit -m "oops'
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}
