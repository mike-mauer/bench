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
#   • conservative— clears the local engine ONLY when bd EXPLICITLY reported an
#                   empty board ("0") AND a recovery source is PROVEN to exist
#                   first (origin refs/dolt/data, or a committed non-empty
#                   issues.jsonl). Never "delete, then hope" (Bench-rm4);
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

# ── JSONL merge strategy (auto-heal, idempotent, runs before the hydrate check) ──
# .beads/*.jsonl (issues.jsonl, interactions.jsonl) are git-tracked but are one-way
# DERIVED exports of the Dolt board. Parallel / ephemeral cloud containers each
# re-export them and collide on the same lines → spurious merge conflicts on every
# commit. A `merge=union` git attribute (a BUILT-IN strategy — no .git/config driver
# to register, so it survives fresh clones) makes git keep both sides instead of
# conflicting; the next `bd export` rewrites the file clean from the authoritative
# board. We write it here, on the SessionStart path, so EXISTING installs pick up the
# fix on their next session without re-running /bench:init. Best-effort; the file is
# left in the working tree for the user to commit (a hook must never auto-commit).
ga="$ROOT/.beads/.gitattributes"
if ! grep -q 'merge=union' "$ga" 2>/dev/null; then
  {
    printf '# beads JSONL are one-way DERIVED exports of the Dolt board (source of truth:\n'
    printf '# refs/dolt/data, which cell-merges). merge=union keeps both sides instead of\n'
    printf '# conflicting; the next `bd export` rewrites clean. Never hand-resolve.\n'
    printf '*.jsonl merge=union\n'
  } >> "$ga" 2>/dev/null \
    && log "wrote .beads/.gitattributes (merge=union) — commit it to stop JSONL merge conflicts."
fi

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

# DESTRUCTIVE-CLEAR SAFETY GATE (Bench-rm4).
# Never remove the local engine unless a recovery source is PROVEN to exist first.
# "Delete, then hope" loses the board when origin carries no refs/dolt/data and
# issues.jsonl was never committed. A recovery source is either:
#   (a) refs/dolt/data on origin (or already fetched into a local ref above), or
#   (b) a committed, NON-EMPTY .beads/issues.jsonl at HEAD.
recovery_source=""
if git rev-parse --verify -q refs/dolt/data >/dev/null 2>&1 \
   || git ls-remote --exit-code origin 'refs/dolt/data' >/dev/null 2>&1; then
  recovery_source="dolt-ref"
elif git cat-file -e HEAD:.beads/issues.jsonl 2>/dev/null \
     && [ "$(git cat-file -s HEAD:.beads/issues.jsonl 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
  recovery_source="jsonl-export"
fi

# Clear the local engine ONLY when bd reported "0" AND recovery is proven.
if [ "$count" = "0" ] && [ -n "$recovery_source" ]; then
  log "recovery source present ($recovery_source) — clearing cold engine before rehydrate."
  rm -rf .beads/embeddeddolt .beads/dolt 2>/dev/null || true
elif [ "$count" = "0" ]; then
  log "WARNING: cold board but NO recovery source — refusing to clear the local engine."
  log "WARNING: your only copy may be local. Run 'bd dolt push' and commit .beads/issues.jsonl."
fi

# Blanking BD_SYNC_REMOTE makes bootstrap skip any unreachable configured remote
# and auto-detect the reachable git origin (refs/dolt/data), falling back to the
# committed issues.jsonl export if origin carries no Dolt data. With neither source
# this is a safe no-op — nothing was deleted above.
if BD_SYNC_REMOTE="" bd bootstrap --yes >/dev/null 2>&1; then
  log "rehydrate complete."
else
  log "rehydrate failed (non-fatal) — run 'bd bootstrap' manually if needed."
fi
exit 0
