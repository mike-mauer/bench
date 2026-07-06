#!/usr/bin/env bash
# scripts/install-bd.sh — ensure the beads (bd) CLI is available, at a pinned version.
#
# Invoked from hooks.json on SessionStart. The Bench plugin depends on the beads
# plugin for its `bd prime` hooks, but the beads plugin does NOT bundle the bd
# binary — this script supplies it.
#
# Design:
#   • Idempotent — if `bd` is already on PATH, this is a no-op (we respect an
#     existing install; the beads-health-check skill flags version drift).
#   • Version-pinned — installs the version from the plugin's `bd_version` config
#     (exported as CLAUDE_PLUGIN_OPTION_BD_VERSION; default 1.0.4) because the
#     upstream installer always grabs "latest" and can't pin.
#   • Update-surviving — installs into ${CLAUDE_PLUGIN_DATA}/bin, the persistent
#     plugin data dir, so a plugin update doesn't re-download.
#   • Off the critical path — the actual download runs detached so SessionStart
#     never blocks; PATH is exported up front so bd appears as soon as it lands.
#   • Best-effort — every path exits 0; this hook must never wedge a session.
set -uo pipefail

log() { printf '[install-bd] %s\n' "$*" >&2; }

VERSION="${CLAUDE_PLUGIN_OPTION_BD_VERSION:-1.0.4}"
VERSION="${VERSION#v}"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.bench-data}"
BIN_DIR="$DATA_DIR/bin"

# semver compare: echoes "gt" if $1 > $2, "lt" if <, "eq" if equal. Best-effort;
# on any unparseable (non-numeric) input it stays silent so callers no-op.
semver_cmp() {
  _a="$1"; _b="$2"
  case "$_a$_b" in *[!0-9.]*) return 0;; esac  # non-numeric — bail quietly
  _IFS_save="$IFS"; IFS=.
  # shellcheck disable=SC2086  # deliberate word-split on '.'
  set -- $_a; a1="${1:-0}"; a2="${2:-0}"; a3="${3:-0}"
  # shellcheck disable=SC2086
  set -- $_b; b1="${1:-0}"; b2="${2:-0}"; b3="${3:-0}"
  IFS="$_IFS_save"
  for pair in "$a1 $b1" "$a2 $b2" "$a3 $b3"; do
    # shellcheck disable=SC2086
    set -- $pair
    { [ "$1" -gt "$2" ]; } 2>/dev/null && { echo gt; return 0; }
    { [ "$1" -lt "$2" ]; } 2>/dev/null && { echo lt; return 0; }
  done
  echo eq
}

# Non-blocking pin/shadowing check across ALL bd on PATH (root cause #2 of
# Bench-usv). Enumerates every `bd` via `command -v -a` / `which -a` — not just
# the first — because the plugin's pinned copy sits first and hides any newer
# system bd behind it. A newer-than-pin bd behind the pin is the dangerous case:
# on a board already migrated to that newer bd's schema (e.g. v53), the pinned
# bd's writes hard-fail with `Error 1105: Field id doesn't have a default value`
# — silently, so agent handoff writes are lost. We warn loudly (naming BOTH
# binaries + the symptom) and drop a breadcrumb; we never auto-switch (running
# the newer bd could one-way-migrate the board). A stale breadcrumb is removed
# when the only bd(s) on PATH match the pin. Never changes the exit code.
check_pin_drift() {
  # Enumerate ALL bd on PATH, dedup preserving order. `which -a` / `type -a` are
  # the reliable enumerators — do NOT use `command -v -a`: POSIX `command -v`
  # takes no `-a` and either errors or returns only the FIRST match, which is the
  # first-only blindness this whole function exists to fix.
  bins=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) : ;; *) continue;; esac  # keep absolute paths only
    [ -x "$p" ] || continue
    case ":$bins:" in *":$p:"*) continue;; esac
    bins="${bins:+$bins:}$p"
  done <<EOF
$( { which -a bd 2>/dev/null || type -a -p bd 2>/dev/null; } || true )
EOF
  [ -n "$bins" ] || return 0  # no bd at all — say nothing

  # Describe each bd relative to the PIN (not to PATH position — position can flip
  # depending on whether BIN_DIR has landed on PATH yet at hook time).
  pin_path=""                  # a bd on PATH that matches the pin exactly
  newer_path=""; newer_ver=""  # a bd strictly NEWER than the pin (the hazard)
  drift_path=""; drift_ver=""  # first bd whose version != the pin (any direction)
  _IFS_save="$IFS"; IFS=:
  for bd_path in $bins; do
    IFS="$_IFS_save"
    ver="$("$bd_path" version 2>/dev/null | head -1 | cut -d' ' -f3)"
    [ -n "$ver" ] || { IFS=:; continue; }
    if [ "$ver" = "$VERSION" ]; then
      [ -n "$pin_path" ] || pin_path="$bd_path"
    else
      [ -n "$drift_path" ] || { drift_path="$bd_path"; drift_ver="$ver"; }
      if [ -z "$newer_path" ] && [ "$(semver_cmp "$ver" "$VERSION")" = "gt" ]; then
        newer_path="$bd_path"; newer_ver="$ver"
      fi
    fi
    IFS=:
  done
  IFS="$_IFS_save"

  # Clean: the only bd(s) on PATH match the pin exactly.
  if [ -z "$drift_path" ]; then
    rm -f "$DATA_DIR/pin-drift" 2>/dev/null || true
    return 0
  fi

  # The plugin's own pinned copy, if it happens to be on PATH — the "pinned bd" we
  # name in the warning. Fall back to BIN_DIR/bd (where we install it) so the
  # message is correct even when the pinned copy is NOT the first bd resolved.
  pinned_label="${pin_path:-$BIN_DIR/bd}"

  mkdir -p "$DATA_DIR" 2>/dev/null || return 0
  if [ -n "$newer_path" ]; then
    # The dangerous case: a bd NEWER than the pin is on PATH. If the pinned copy
    # resolves before it, the pinned bd's writes fail on a schema-ahead board.
    log "WARNING: a bd NEWER than the pin is on PATH: $newer_ver at $newer_path (plugin pins $VERSION; pinned copy at $pinned_label)."
    log "  If this project's board has been migrated to the newer bd's schema, EVERY write from the pinned bd will fail with:"
    log "    Error 1105: Field id doesn't have a default value"
    log "  — silently (issues/comments are NOT created; agent handoff writes are lost). See the beads-health-check skill."
    {
      echo "found-version: $newer_ver"
      echo "pinned-version: $VERSION"
      echo "path: $newer_path"
      echo "pinned-path: $pinned_label"
      echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "reason: newer bd shadowed behind pinned copy (Bench-usv); pinned writes fail Error 1105 on a migrated board"
    } > "$DATA_DIR/pin-drift" 2>/dev/null || true
  else
    # Older or otherwise-divergent bd — the pre-existing generic drift warning.
    log "WARNING: bd on PATH is $drift_ver ($drift_path) but the plugin pins $VERSION — see the beads-health-check skill for drift policy."
    {
      echo "found-version: $drift_ver"
      echo "pinned-version: $VERSION"
      echo "path: $drift_path"
      echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$DATA_DIR/pin-drift" 2>/dev/null || true
  fi
  return 0
}

# Expose bd's likely locations on PATH for the rest of the session, so bd is
# usable the moment the (possibly detached) install lands.
#
# Root cause #1 (Bench-usv): we must NOT unconditionally PREPEND BIN_DIR — once
# the pinned copy exists it would shadow any pre-existing (possibly newer) system
# bd forever, in every project, contradicting the "respect an existing install"
# design. So: if a bd is already resolvable on PATH, we only APPEND our fallback
# locations (the system bd stays first); only when no bd is present do we put
# BIN_DIR up front, since our pinned install is then the only candidate.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    if command -v bd >/dev/null 2>&1; then
      # A bd already resolves — respect it; append our dirs behind it.
      echo "export PATH=\"\$PATH:$BIN_DIR:\$HOME/.local/bin\""
    else
      # No bd yet — the pinned copy we're about to install must lead.
      echo "export PATH=\"$BIN_DIR:\$PATH:\$HOME/.local/bin\""
    fi
    if command -v go >/dev/null 2>&1; then
      echo "export PATH=\"\$PATH:$(go env GOPATH 2>/dev/null)/bin\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

# Already have bd somewhere on PATH? Respect it — nothing to install.
if command -v bd >/dev/null 2>&1; then
  check_pin_drift   # enumerates ALL bd on PATH, not just the first
  bash "$(dirname "${BASH_SOURCE[0]}")/beads-bootstrap.sh" >/dev/null 2>&1 || true
  exit 0
fi

# Already installed our pinned copy in a previous session?
if [ -x "$BIN_DIR/bd" ]; then
  check_pin_drift
  bash "$(dirname "${BASH_SOURCE[0]}")/beads-bootstrap.sh" >/dev/null 2>&1 || true
  exit 0
fi

# Test hook: skip the detached network install so the bats suite is hermetic.
# (SessionStart always runs the real path; this var is set only by tests/.)
if [ -n "${BENCH_TEST_NO_INSTALL:-}" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The detached shell logs here from its first line — make sure the dir exists first.
mkdir -p "$DATA_DIR" 2>/dev/null || true
LOG_FILE="$DATA_DIR/install.log"

# The slow part (network + extract) runs detached so SessionStart returns now.
# VERSION/BIN_DIR/SCRIPT_DIR/DATA_DIR are passed as environment variables (not
# spliced into the script text) so paths with spaces/quotes survive intact.
# shellcheck disable=SC2016  # single quotes are deliberate: the inner script expands these vars itself, from its environment
VERSION="$VERSION" BIN_DIR="$BIN_DIR" SCRIPT_DIR="$SCRIPT_DIR" DATA_DIR="$DATA_DIR" \
setsid nohup bash -c '
  set -uo pipefail
  log() { printf "[install-bd] %s\n" "$*" >> "$DATA_DIR/install.log"; }
  mkdir -p "$BIN_DIR"

  os=""; arch=""
  case "$(uname -s)" in Darwin) os=darwin;; Linux) os=linux;; FreeBSD) os=freebsd;; *) os=$(uname -s);; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; *) arch=$(uname -m);; esac

  # 1) Pinned release tarball (no toolchain needed).
  url="https://github.com/gastownhall/beads/releases/download/v${VERSION}/beads_${VERSION}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/bd.tgz" 2>/dev/null && tar -xzf "$tmp/bd.tgz" -C "$tmp" 2>/dev/null; then
    found="$(find "$tmp" -type f -name bd | head -1)"
    if [ -n "$found" ]; then install -m 0755 "$found" "$BIN_DIR/bd" && log "installed bd v${VERSION} from release tarball."; fi
  fi
  rm -rf "$tmp"

  # 2) Fallback: pinned go install into BIN_DIR.
  # NOTE: the module path is github.com/steveyegge/beads even though the repo now
  # lives at github.com/gastownhall/beads (used for the tarball URL above) — the
  # repo was renamed/moved but its go.mod still declares the original module path.
  if [ ! -x "$BIN_DIR/bd" ] && command -v go >/dev/null 2>&1; then
    if GOBIN="$BIN_DIR" CGO_ENABLED=1 GOFLAGS="-tags=gms_pure_go" go install "github.com/steveyegge/beads/cmd/bd@v${VERSION}" 2>/dev/null \
    || GOBIN="$BIN_DIR" CGO_ENABLED=0 go install "github.com/steveyegge/beads/cmd/bd@v${VERSION}" 2>/dev/null; then
      log "installed bd v${VERSION} via go install."
    fi
  fi

  # Installed at the pin? Clear any stale drift breadcrumb from a prior session.
  if [ -x "$BIN_DIR/bd" ]; then
    rm -f "$DATA_DIR/pin-drift" 2>/dev/null || true
  fi

  # 3) Last resort: upstream installer (LATEST — pin not honored).
  if [ ! -x "$BIN_DIR/bd" ] && ! command -v bd >/dev/null 2>&1; then
    if curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash >/dev/null 2>&1; then
      log "WARNING: installed bd via upstream installer — this is an UNPINNED latest version, not the pinned v${VERSION}. See the beads-health-check skill for drift policy."
      fb_path="$(PATH="$BIN_DIR:$PATH:$HOME/.local/bin" command -v bd 2>/dev/null || true)"
      fb_found="unknown"
      if [ -n "$fb_path" ]; then
        v="$("$fb_path" version 2>/dev/null | head -1 | cut -d" " -f3)"
        [ -n "$v" ] && fb_found="$v"
      fi
      {
        echo "found-version: $fb_found"
        echo "pinned-version: $VERSION"
        echo "path: ${fb_path:-unknown}"
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "reason: fallback installed latest"
      } > "$DATA_DIR/pin-drift" 2>/dev/null || true
    else
      log "bd install failed (non-fatal)."
    fi
  fi

  # Once bd has landed, rehydrate a cold board (idempotent, best-effort).
  PATH="$BIN_DIR:$PATH:$HOME/.local/bin" bash "$SCRIPT_DIR/beads-bootstrap.sh" >/dev/null 2>&1 || true
' >"$LOG_FILE" 2>&1 &
disown 2>/dev/null || true

log "installing beads (bd) v${VERSION} in the background → $LOG_FILE"
exit 0
