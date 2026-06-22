#!/usr/bin/env bash
# scripts/beads-cloud-push.sh — cloud-only SessionEnd push of bead writes.
#
# The warn-only stop guard deliberately never commits or pushes: at SessionEnd a
# human is assumed present to read the warning and run the close protocol. That
# premise fails in an unattended cloud container — nobody reads the warning and the
# container is then destroyed, so any bead writes that never reached the remote are
# lost. This companion hook covers ONLY that gap, and only that payload:
#   • web-only    — a no-op unless CLAUDE_CODE_REMOTE=true (local keeps the
#                   warn-only, human-in-the-loop contract unchanged);
#   • beads-only  — it pushes the Dolt history, never git/code commits (the bead
#                   board is append-mostly metadata with row-level merge, so
#                   pull-then-push is safe; auto-pushing ambiguous WIP code is not);
#   • non-fatal   — every path exits 0; a teardown hook must never wedge teardown.
set -uo pipefail

cat >/dev/null 2>&1   # consume stdin
log() { printf '[beads-cloud-push] %s\n' "$*" >&2; }

# Web-only. Local sessions keep the warn-only guard's human-in-the-loop contract.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0
command -v bd >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -d .beads ] || exit 0

# The reachable Dolt remote is the git origin (the session proxy). Point bd at it
# transiently via env — never write the proxy URL into tracked .beads/config.yaml.
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
[ -n "$ORIGIN" ] || exit 0
export BD_SYNC_REMOTE="git+${ORIGIN}"

log "pushing bead writes to origin…"
bd dolt pull >/dev/null 2>&1 || true
if bd dolt push >/dev/null 2>&1; then
  log "bead writes pushed."
else
  log "dolt push did not complete (non-fatal)."
fi
exit 0
