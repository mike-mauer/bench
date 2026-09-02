#!/usr/bin/env bats
# Tests for plugins/bench/scripts/beads-cloud-push.sh — the Stop/SessionEnd hook
# that persists bead (Dolt) writes out of an ephemeral cloud container.
#
# The bug these pin down (Bench-cz6): `bd dolt push` EXITS 0 when it did nothing.
# With no Dolt remote registered — the state of every fresh cloud container, since
# `bd dolt remote add` writes to the gitignored engine — it prints
# "No remote is configured — skipping" and returns 0. The hook's push_once was
# `bd dolt push >/dev/null 2>&1`, so that silent no-op was read as SUCCESS: the
# failure marker was deleted and SessionEnd logged "bead writes pushed." while the
# writes never left the container. That is precisely the silent revert the script
# exists to prevent, and it reported success while causing it.
#
# So: a push counts only when the OUTPUT proves it happened, failures that
# retrying cannot fix must not spin the backoff into session teardown, and a
# broken channel must be announced early — not only at SessionEnd, which a
# reclaimed container never reaches.
#
# Technique: a stub `bd` first on PATH whose `dolt push` output/exit are set per
# test and whose every call is appended to $BD_LOG.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/beads-cloud-push.sh"

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@test.invalid"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@test.invalid"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$REPO"
  git -C "$REPO" remote add origin "$ORIGIN"
  echo bench > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m initial
  mkdir -p "$REPO/.beads"

  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  # `dolt push` prints $BD_PUSH_OUTPUT and exits $BD_PUSH_EXIT. When
  # $BD_PUSH_OK_AFTER is set, the Nth and later pushes succeed instead — for the
  # transient-failure retry path.
  cat > "$STUB_DIR/bd" <<'EOF'
#!/usr/bin/env bash
echo "bd $*" >> "$BD_LOG"
if [ "$1 $2" = "dolt push" ]; then
  n=$(( $(grep -c '^bd dolt push' "$BD_LOG") ))
  if [ -n "${BD_PUSH_OK_AFTER:-}" ] && [ "$n" -ge "$BD_PUSH_OK_AFTER" ]; then
    echo "Pushing to Dolt remote..."; echo "Done"; exit 0
  fi
  printf '%s\n' "${BD_PUSH_OUTPUT-}"
  exit "${BD_PUSH_EXIT:-0}"
fi
exit 0
EOF
  chmod +x "$STUB_DIR/bd"
  export BD_LOG="$BATS_TEST_TMPDIR/bd.log"; : > "$BD_LOG"
  export PATH="$STUB_DIR:$PATH"

  export CLAUDE_PROJECT_DIR="$REPO"
  export CLAUDE_CODE_REMOTE=true        # the hook is web-only
  export BENCH_TEST_FAST_RETRY=1        # collapse the backoff; real runs sleep
  export BENCH_PUSH_TIMEOUT=5           # bound each attempt (real default: 60s)
  MARKER="$REPO/.beads/.cloud-push-failed"
  BLOCKED="$REPO/.beads/.cloud-push-blocked"

  # The exact bd 1.1.0 no-op: prints, and exits 0.
  NO_REMOTE='Pushing to Dolt remote...
No remote is configured — skipping.

For solo use, pushing is optional — your issues are stored locally
in .beads/ and versioned by Dolt automatically.'
}

# The script consumes stdin by design; feed it EOF or it blocks forever here.
run_hook() { run bash "$SCRIPT" "$@" </dev/null; }

push_count() { grep -c '^bd dolt push' "$BD_LOG"; }

@test "no remote configured (bd exits 0): final does NOT report success" {
  export BD_PUSH_OUTPUT="$NO_REMOTE" BD_PUSH_EXIT=0

  run_hook final

  [ "$status" -eq 0 ]                       # a hook never wedges the session
  [[ "$output" != *"bead writes pushed"* ]] # …but it must not claim success
  [[ "$output" == *"ERROR"* ]]
  [ -f "$MARKER" ]
  grep -q 'No remote is configured' "$MARKER"
}

@test "no remote configured: incremental keeps the failure marker instead of clearing it" {
  export BD_PUSH_OUTPUT="$NO_REMOTE" BD_PUSH_EXIT=0
  : > "$MARKER"     # a previous session recorded a failure

  run_hook incremental

  [ "$status" -eq 0 ]
  [ -f "$MARKER" ]  # the no-op must not be mistaken for a recovery
}

@test "no remote configured: incremental warns ONCE per session, early" {
  export BD_PUSH_OUTPUT="$NO_REMOTE" BD_PUSH_EXIT=0

  run_hook incremental
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT reaching the remote"* ]]
  [[ "$output" == *"bd export"* ]]          # names the channel that does work
  [ -f "$BLOCKED" ]

  # Same session: silent, and — the point of the breaker — it does not pay for
  # the doomed push again. A blocked refs/dolt push takes ~45s to return its 403,
  # and Stop runs after EVERY turn.
  before="$(push_count)"
  run_hook incremental
  [ "$status" -eq 0 ]
  [[ "$output" != *"NOT reaching the remote"* ]]
  [ "$(push_count)" -eq "$before" ]
}

@test "a tripped breaker makes SessionEnd report without re-attempting the push" {
  export BD_PUSH_OUTPUT='Error: RPC failed; HTTP 403' BD_PUSH_EXIT=1
  run_hook incremental                    # trips the breaker
  [ -f "$BLOCKED" ]
  before="$(push_count)"

  run_hook final

  [ "$status" -eq 0 ]
  [ "$(push_count)" -eq "$before" ]       # no further attempt
  [[ "$output" == *"already established as unavailable"* ]]
  [[ "$output" != *"bead writes pushed"* ]]
  [ -f "$MARKER" ]
  grep -q '403' "$MARKER"                 # the stored reason still reaches the marker
}

@test "a later successful push clears both the marker and the breaker" {
  export BD_PUSH_OUTPUT='Error: RPC failed; HTTP 403' BD_PUSH_EXIT=1
  run_hook incremental
  [ -f "$BLOCKED" ]

  rm -f "$BLOCKED"                        # SessionStart clears it; channel now works
  export BD_PUSH_OUTPUT='Pushing to Dolt remote...
Done' BD_PUSH_EXIT=0
  run_hook final

  [ "$status" -eq 0 ]
  [[ "$output" == *"bead writes pushed"* ]]
  [ ! -e "$MARKER" ]
  [ ! -e "$BLOCKED" ]
}

@test "a real push clears the marker and reports success" {
  export BD_PUSH_OUTPUT='Pushing to Dolt remote...
Done' BD_PUSH_EXIT=0
  : > "$MARKER"

  run_hook final

  [ "$status" -eq 0 ]
  [[ "$output" == *"bead writes pushed"* ]]
  [ ! -e "$MARKER" ]
}

@test "permanent failure (blocked refs/dolt push) fails fast — no retry storm" {
  export BD_PUSH_OUTPUT='Error: push to origin/main: unknown push error; RPC failed; HTTP 403
send-pack: unexpected disconnect while reading sideband packet' BD_PUSH_EXIT=1

  run_hook final

  [ "$status" -eq 0 ]
  # One attempt, not the 5-deep backoff (which would stall session teardown ~30s
  # on a channel that cannot succeed), and no pull-reconcile either.
  [ "$(push_count)" -eq 1 ]
  ! grep -q '^bd dolt pull' "$BD_LOG"
  [ -f "$MARKER" ]
  grep -q '403' "$MARKER"
  grep -q 'bd export' "$MARKER"   # the marker names the channel that does work
}

@test "transient failure retries and succeeds" {
  export BD_PUSH_OUTPUT='Error: push rejected: non-fast-forward' BD_PUSH_EXIT=1
  export BD_PUSH_OK_AFTER=3      # 1st and 2nd fail, 3rd succeeds

  run_hook final

  [ "$status" -eq 0 ]
  [[ "$output" == *"bead writes pushed"* ]]
  [ "$(push_count)" -eq 3 ]
  [ ! -e "$MARKER" ]
}

@test "persistent non-fast-forward: pull-reconcile is still attempted, then the marker" {
  export BD_PUSH_OUTPUT='Error: push rejected: non-fast-forward' BD_PUSH_EXIT=1

  run_hook final

  [ "$status" -eq 0 ]
  grep -q '^bd dolt pull' "$BD_LOG"
  [ -f "$MARKER" ]
  [[ "$output" != *"bead writes pushed"* ]]
}

@test "local (non-cloud) session: the hook is a no-op and never calls bd" {
  unset CLAUDE_CODE_REMOTE
  export BD_PUSH_OUTPUT="$NO_REMOTE"

  run_hook final

  [ "$status" -eq 0 ]
  [ ! -s "$BD_LOG" ]
  [ ! -e "$MARKER" ]
}

@test "a slow push that times out: turns stay fast, but SessionEnd still tries once" {
  # `bd dolt push` that never returns — the hook must not hold the turn open.
  cat > "$STUB_DIR/bd" <<'EOF'
#!/usr/bin/env bash
echo "bd $*" >> "$BD_LOG"
[ "$1 $2" = "dolt push" ] && { sleep 30; exit 0; }
exit 0
EOF
  chmod +x "$STUB_DIR/bd"
  export BENCH_PUSH_TIMEOUT=1

  run_hook incremental
  [ "$status" -eq 0 ]
  [[ "$output" == *"exceeded 1s"* ]]
  [ -f "$BLOCKED" ]

  before="$(push_count)"
  run_hook incremental            # breaker: no second timeout this turn
  [ "$(push_count)" -eq "$before" ]

  # SessionEnd is the last chance to persist, and a timeout may just be a slow
  # link — so unlike a hard 403 it still gets one bounded attempt.
  run_hook final
  [ "$status" -eq 0 ]
  [ "$(push_count)" -gt "$before" ]
  [[ "$output" != *"already established as unavailable"* ]]
}
