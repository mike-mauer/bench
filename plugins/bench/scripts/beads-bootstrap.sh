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

# ── .beads permissions (Bench-fbc) ────────────────────────────────────────────
# bd warns on EVERY invocation when .beads is group/world-readable, and a fresh
# clone lands 0755 — so in a cloud container that warning prefixes every bd call
# in every agent transcript, burying the warnings that matter (pin drift, cold
# board, a failed push). Best-effort; never fatal.
chmod 700 "$ROOT/.beads" 2>/dev/null || true

# ── Per-session state reset ───────────────────────────────────────────────────
# beads-cloud-push trips a circuit breaker when it proves the push channel is
# broken, so it stops paying ~45s per turn for a doomed push. That verdict is
# per-SESSION: a new container (or a changed network policy) deserves one fresh
# probe, so clear it here. The failure marker is left alone — it is the durable
# record that writes went unpersisted, and only a successful push clears it.
rm -f "$ROOT/.beads/.cloud-push-blocked" 2>/dev/null || true

# Keep those container-local breadcrumbs out of `git status` (and out of commits):
# they describe THIS container, never the project.
gi="$ROOT/.beads/.gitignore"
if ! grep -q 'cloud-push' "$gi" 2>/dev/null; then
  {
    printf '\n# Bench: container-local breadcrumbs from the cloud-push hook.\n'
    printf '.cloud-push-failed\n.cloud-push-blocked\n'
  } >> "$gi" 2>/dev/null || true
fi

# ── Dolt remote materialization (Bench-4m0) ───────────────────────────────────
# `bd dolt remote add` stores the remote in the LOCAL Dolt engine
# (.beads/embeddeddolt, gitignored), so a fresh clone — i.e. EVERY cloud
# container — starts with no remote at all. `bd dolt push` then reads neither
# BD_SYNC_REMOTE nor .beads/config.yaml's sync.remote (verified, bd 1.1.0): it
# prints "No remote is configured — skipping" and exits 0, which is how bead
# writes silently failed to persist (Bench-cz6). So re-register the remote on
# every cold start, from the COMMITTED record (sync.remote) or the git origin —
# making a file in git, not container-local state, the durable source of truth.
ensure_dolt_remote() {
  # Already configured in this engine? Leave it alone (never override a remote
  # the project or the user set deliberately).
  case "$(bd dolt remote list 2>/dev/null)" in
    *"://"*) return 0 ;;
  esac

  url="$(sed -n 's/^[[:space:]]*sync\.remote:[[:space:]]*//p' "$ROOT/.beads/config.yaml" 2>/dev/null \
         | head -1 | sed -e 's/^"//' -e 's/"$//')"
  [ -n "$url" ] || url="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 0

  # Normalize to a form bd accepts. A BARE https:// URL is read as a DoltHub
  # gRPC remote (which fails through an HTTP proxy); the `git+` prefix selects
  # git transport, which is what a GitHub-hosted refs/dolt/data needs.
  case "$url" in
    git+*)              : ;;
    git@*:*)            url="git+ssh://${url%%:*}/${url#*:}" ;;
    ssh://*)            url="git+$url" ;;
    https://*|http://*) url="git+${url%.git}.git" ;;
    *)                  return 0 ;;   # unknown scheme — don't guess
  esac

  # `bd dolt remote add` also rewrites sync.remote in the TRACKED config.yaml. A
  # hook must not leave a tracked file dirty, and must never bake a container's
  # proxy URL into the repo — so snapshot a clean config and put it back after.
  cfg="$ROOT/.beads/config.yaml"
  snap=""
  if [ -f "$cfg" ] \
     && git -C "$ROOT" ls-files --error-unmatch .beads/config.yaml >/dev/null 2>&1 \
     && git -C "$ROOT" diff --quiet -- .beads/config.yaml 2>/dev/null; then
    snap="$(mktemp 2>/dev/null || true)"
    [ -n "$snap" ] && cp -f "$cfg" "$snap" 2>/dev/null
  fi

  if bd dolt remote add origin "$url" >/dev/null 2>&1; then
    log "registered Dolt remote origin → $url (cold container had none)."
  else
    log "could not register a Dolt remote (non-fatal) — bead writes may not persist."
  fi

  if [ -n "$snap" ] && ! git -C "$ROOT" diff --quiet -- .beads/config.yaml 2>/dev/null; then
    cp -f "$snap" "$cfg" 2>/dev/null && log "restored tracked .beads/config.yaml (bd rewrote sync.remote)."
  fi
  [ -n "$snap" ] && rm -f "$snap" 2>/dev/null
  return 0
}
ensure_dolt_remote

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
