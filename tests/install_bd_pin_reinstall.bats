#!/usr/bin/env bats
# Tests for plugins/bench/scripts/install-bd.sh reinstall-on-pin-change (Bench-nfh.1).
#
# Bug: the second early-exit block ("Already installed our pinned copy in a
# previous session?", `[ -x "$BIN_DIR/bd" ]`) exits 0 UNCONDITIONALLY once a
# pinned copy exists under BIN_DIR. So after the plugin's `bd_version` pin is
# bumped (e.g. 1.0.4 -> 1.1.0), the SessionStart hook never replaces the
# previously installed binary — the machine keeps running the OLD bd forever.
#
# Fix: when BIN_DIR/bd's reported version != the configured pin, do NOT early-exit;
# log the decision and fall through to the (detached, best-effort) install path so
# the pinned version is reinstalled over the stale copy. When it already matches,
# keep the early-exit (no needless reinstall).
#
# Reaching the SECOND block requires `command -v bd` to FAIL first, so these tests
# put the stale binary at BIN_DIR/bd but deliberately do NOT add BIN_DIR to PATH
# (which mirrors reality: at SessionStart the env-file isn't sourced yet). The two
# branches both end in `exit 0`, so status can't distinguish them — we assert on a
# distinct log line the reinstall decision emits.
#
# Every path must exit 0 (SessionStart hook must never wedge).

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/install-bd.sh"

setup() {
  DATA_DIR="$BATS_TEST_TMPDIR/data"
  BIN_DIR="$DATA_DIR/bin"
  mkdir -p "$BIN_DIR"

  export CLAUDE_PLUGIN_DATA="$DATA_DIR"
  export CLAUDE_ENV_FILE="$BATS_TEST_TMPDIR/env-file"
  : > "$CLAUDE_ENV_FILE"
  export BENCH_TEST_NO_INSTALL=1

  # Clean PATH: no bd resolvable via `command -v`, so control reaches the
  # `[ -x "$BIN_DIR/bd" ]` block. Keep system dirs so coreutils still resolve.
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

@test "installed BIN_DIR/bd is OLDER than the pin: hook logs a reinstall decision (does not silently keep the stale copy)" {
  make_bd "$BIN_DIR" "1.0.4"                       # stale copy from a previous session
  export CLAUDE_PLUGIN_OPTION_BD_VERSION="1.1.0"   # pin has since been bumped

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # The hook must recognize the version mismatch and announce a reinstall — the
  # current script exits 0 here with no such line (the bug under test).
  [[ "$output" == *"reinstall"* ]]
  [[ "$output" == *"1.0.4"* ]]
  [[ "$output" == *"1.1.0"* ]]
}

@test "installed BIN_DIR/bd MATCHES the pin: no reinstall, early-exit stays" {
  make_bd "$BIN_DIR" "1.1.0"
  export CLAUDE_PLUGIN_OPTION_BD_VERSION="1.1.0"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # Matching version must NOT trigger a reinstall (avoid needless re-download).
  [[ "$output" != *"reinstall"* ]]
}
