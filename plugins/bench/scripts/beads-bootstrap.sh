#!/usr/bin/env bash
# scripts/beads-bootstrap.sh — cold-start rehydrate of the beads board.
#
# A fresh clone (a new teammate, or an ephemeral cloud container) gets the repo
# but NOT the Dolt database (.beads/embeddeddolt is gitignored). On the first `bd`
# call bd creates an EMPTY database, so the board shows zero issues even though it
# has hundreds. The committed .beads/issues.jsonl is an export, not an auto-import;
# the reachable Dolt history lives on the git `origin` under refs/dolt/data.
#
# This detects a cold board and rehydrates it from origin. It is:
#   • bd-safe     — a no-op when bd isn't installed yet;
#   • idempotent  — skips entirely when the board is already hydrated;
#   • conservative— only ever clears a board bd EXPLICITLY reported as empty ("0");
#   • best-effort — every path exits 0; it must never wedge session start.
#
# Invoked by install-bd.sh once the bd binary has landed (so a slow clone never
# delays session start).
set -uo pipefail

log() { printf '[beads-bootstrap] %s\n' "$*" >&2; }

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" 2>/dev/null || exit 0

command -v bd >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -d "$ROOT/.beads" ] || exit 0   # not a beads project

# A fresh/empty embedded DB reports "0"; a blank string means bd couldn't report
# (don't treat that as "empty" — never destructive on an error).
count="$(bd stats --json 2>/dev/null | grep -o '"total_issues"[: ]*[0-9]*' | grep -o '[0-9]*$' | head -1)"
if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
  log "board already hydrated ($count issues) — nothing to do."
  exit 0
fi

log "cold board detected — rehydrating from git origin…"

# A normal clone does not fetch custom refs; bring origin's Dolt history in.
git fetch origin 'refs/dolt/*:refs/dolt/*' 2>/dev/null || true

# Only clear the local DB when bd EXPLICITLY reported an empty board ("0").
if [ "$count" = "0" ]; then
  rm -rf .beads/embeddeddolt .beads/dolt 2>/dev/null || true
fi

# Blanking BD_SYNC_REMOTE makes bootstrap skip any unreachable configured remote
# and auto-detect the reachable git origin (refs/dolt/data), falling back to the
# committed issues.jsonl export if origin carries no Dolt data.
if BD_SYNC_REMOTE="" bd bootstrap --yes >/dev/null 2>&1; then
  log "rehydrate complete."
else
  log "rehydrate failed (non-fatal) — run 'bd bootstrap' manually if needed."
fi
exit 0
