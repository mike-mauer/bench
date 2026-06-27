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

# Warn (never fail) when the bd that will actually run differs from the pinned
# version. Drift is silent and bites downstream: an unpinned bd means the harness
# runs a version it was not validated against, and bd output-shape changes between
# releases can break consumers (e.g. BeadBox stopped rendering comments when a
# Homebrew bd jumped ahead of the pin). See the beads-health-check skill.
warn_if_bd_drift() {
  command -v bd >/dev/null 2>&1 || return 0
  local have where
  have="$(bd version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  where="$(command -v bd 2>/dev/null)"
  if [ -n "$have" ] && [ "$have" != "$VERSION" ]; then
    log "⚠️  bd version drift: PATH bd is v${have} (${where}), but Bench pins v${VERSION}."
    log "    The harness will run v${have} — a version it was not validated against, and"
    log "    bd output-shape changes between releases can break tools (e.g. BeadBox comments)."
    log "    Fix: unlink/remove the other bd (e.g. 'brew unlink beads') so ${BIN_DIR} wins,"
    log "    or set the bd_version plugin config to v${have} if that drift is intentional."
  fi
}

# Export bd's likely locations on PATH for the rest of the session — unconditionally
# and up front, so bd is usable the moment the (possibly detached) install lands.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$BIN_DIR:\$PATH:\$HOME/.local/bin\""
    if command -v go >/dev/null 2>&1; then
      echo "export PATH=\"\$PATH:$(go env GOPATH 2>/dev/null)/bin\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

# Already have bd somewhere on PATH? Respect it — nothing to install — but warn on drift.
if command -v bd >/dev/null 2>&1; then
  warn_if_bd_drift
  bash "$(dirname "${BASH_SOURCE[0]}")/beads-bootstrap.sh" >/dev/null 2>&1 || true
  exit 0
fi

# Already installed our pinned copy in a previous session?
if [ -x "$BIN_DIR/bd" ]; then
  bash "$(dirname "${BASH_SOURCE[0]}")/beads-bootstrap.sh" >/dev/null 2>&1 || true
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The slow part (network + extract) runs detached so SessionStart returns now.
setsid nohup bash -c '
  set -uo pipefail
  log() { printf "[install-bd] %s\n" "$*" >> /tmp/bench-install-bd.log; }
  VERSION="'"$VERSION"'"; BIN_DIR="'"$BIN_DIR"'"; SCRIPT_DIR="'"$SCRIPT_DIR"'"
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
  if [ ! -x "$BIN_DIR/bd" ] && command -v go >/dev/null 2>&1; then
    if GOBIN="$BIN_DIR" CGO_ENABLED=1 GOFLAGS="-tags=gms_pure_go" go install "github.com/steveyegge/beads/cmd/bd@v${VERSION}" 2>/dev/null \
    || GOBIN="$BIN_DIR" CGO_ENABLED=0 go install "github.com/steveyegge/beads/cmd/bd@v${VERSION}" 2>/dev/null; then
      log "installed bd v${VERSION} via go install."
    fi
  fi

  # 3) Last resort: upstream installer (LATEST — pin not honored).
  if [ ! -x "$BIN_DIR/bd" ] && ! command -v bd >/dev/null 2>&1; then
    if curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash >/dev/null 2>&1; then
      log "installed bd via upstream installer (LATEST — could not honor v${VERSION} pin)."
    else
      log "bd install failed (non-fatal)."
    fi
  fi

  # Once bd has landed, rehydrate a cold board (idempotent, best-effort).
  PATH="$BIN_DIR:$PATH:$HOME/.local/bin" bash "$SCRIPT_DIR/beads-bootstrap.sh" >/dev/null 2>&1 || true
' >/tmp/bench-install-bd.log 2>&1 &
disown 2>/dev/null || true

log "installing beads (bd) v${VERSION} in the background → /tmp/bench-install-bd.log"
exit 0
