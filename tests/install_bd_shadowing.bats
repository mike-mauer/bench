#!/usr/bin/env bats
# Tests for plugins/bench/scripts/install-bd.sh drift/shadowing detection (Bench-usv).
#
# Field evidence (2026-07-06): a board migrated to schema v53 by homebrew bd
# 1.1.0, while plain `bd` resolved to the plugin's pinned 1.0.4 (BIN_DIR first on
# PATH). Every write then failed with `Error 1105: Field id doesn't have a
# default value` and the issue/comment was silently NOT created — including
# subagent Worker handoff writes.
#
# Root causes under test:
#   1. install-bd.sh unconditionally PREPENDED BIN_DIR to PATH, so once the
#      pinned copy exists it shadows any newer system bd forever — contradicting
#      the stated "respect an existing install" design. Fix: do not prepend when
#      a bd is already on PATH ahead of BIN_DIR (respect it).
#   2. check_pin_drift inspected only the FIRST bd on PATH (the pinned copy
#      itself), so found==pin and no drift warning ever fired; the newer system
#      bd behind it was invisible. Fix: enumerate ALL bd on PATH (which -a) and
#      warn on pin-vs-system divergence, naming BOTH binaries and the Error-1105
#      failing-writes symptom.
#
# Every path must exit 0 (SessionStart hook must never wedge).
#
# Technique (mirrors beads_bootstrap.bats): build stub `bd` binaries whose
# `version` output is test-controlled, arrange them on PATH, and run the script
# with CLAUDE_ENV_FILE + CLAUDE_PLUGIN_DATA pointed at throwaway files. We assert
# on the drift breadcrumb + warning text and on what the script writes to
# CLAUDE_ENV_FILE (the PATH mutation). BENCH_TEST_NO_INSTALL=1 skips the detached
# network install so tests are hermetic.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/install-bd.sh"

setup() {
  DATA_DIR="$BATS_TEST_TMPDIR/data"
  BIN_DIR="$DATA_DIR/bin"
  SYS_DIR="$BATS_TEST_TMPDIR/sysbin"
  mkdir -p "$BIN_DIR" "$SYS_DIR"

  export CLAUDE_PLUGIN_DATA="$DATA_DIR"
  export CLAUDE_ENV_FILE="$BATS_TEST_TMPDIR/env-file"
  : > "$CLAUDE_ENV_FILE"
  export CLAUDE_PLUGIN_OPTION_BD_VERSION="1.0.4"
  export BENCH_TEST_NO_INSTALL=1

  # A clean PATH with no `bd` on it unless a test adds one, but keep the system
  # dirs so `dirname`, `date`, `command`, etc. still resolve.
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
}

# Create a stub `bd` at $1 reporting version $2 from `bd version`.
make_bd() {
  cat > "$1/bd" <<EOF
#!/usr/bin/env bash
case "\$1" in
  version) echo "bd version $2 (deadbeef: test@deadbeef)" ;;
esac
exit 0
EOF
  chmod +x "$1/bd"
}

# The pinned copy: BIN_DIR/bd at the pinned version, first on PATH.
put_pinned() {
  make_bd "$BIN_DIR" "1.0.4"
  export PATH="$BIN_DIR:$PATH"
}

# A newer system bd on PATH (behind the pinned copy when both are present).
put_system_newer() {
  make_bd "$SYS_DIR" "1.1.0"
  export PATH="$PATH:$SYS_DIR"
}

# --- Root cause #2: drift check must see the newer bd BEHIND the pinned copy ---

@test "pinned copy first + newer system bd behind it: drift warning fires and names both binaries" {
  put_pinned          # BIN_DIR/bd 1.0.4 first
  put_system_newer    # SYS_DIR/bd 1.1.0 behind it

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # A drift breadcrumb must be written (was never written before: found==pin).
  [ -f "$DATA_DIR/pin-drift" ]
  # It must name the NEWER system binary, not just the pinned one.
  grep -q "$SYS_DIR/bd" "$DATA_DIR/pin-drift"
  grep -q "1.1.0" "$DATA_DIR/pin-drift"
}

@test "drift warning quotes the Error-1105 failing-writes symptom" {
  put_pinned
  put_system_newer

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # The actionable warning (stderr) must name both binaries and the exact
  # symptom so a human can recognize it in the wild.
  [[ "$output" == *"Error 1105: Field id doesn't have a default value"* ]]
  [[ "$output" == *"$BIN_DIR/bd"* ]]
  [[ "$output" == *"$SYS_DIR/bd"* ]]
}

@test "no divergence (only the pinned copy on PATH): no drift breadcrumb, exit 0" {
  put_pinned          # only the pinned 1.0.4, nothing behind it

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -f "$DATA_DIR/pin-drift" ]
}

# --- Root cause #1: do not shadow a pre-existing system bd forever ---

@test "pre-existing system bd ahead of BIN_DIR: PATH mutation must NOT prepend BIN_DIR" {
  # System bd already on PATH, BIN_DIR not yet on PATH — the "respect an existing
  # install" case. The script must not force BIN_DIR ahead of it.
  make_bd "$SYS_DIR" "1.1.0"
  export PATH="$SYS_DIR:$PATH"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # Whatever PATH line the script appended to CLAUDE_ENV_FILE must not shove
  # BIN_DIR in front of the already-present system bd.
  if grep -q 'export PATH=' "$CLAUDE_ENV_FILE"; then
    ! grep -qE "export PATH=\"$BIN_DIR:" "$CLAUDE_ENV_FILE"
  fi
}

@test "no bd anywhere on PATH: BIN_DIR is added so the pinned copy will be usable" {
  # Fresh machine: nothing on PATH. The script still needs to expose BIN_DIR so
  # the (detached) install lands somewhere usable.
  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q "$BIN_DIR" "$CLAUDE_ENV_FILE"
}
