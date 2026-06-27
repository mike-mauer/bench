#!/usr/bin/env bash
# scripts/beads-cloud-push.sh — durably persist local bead (Dolt) writes to the
# cloud remote. Wired to BOTH Stop (incremental) and SessionEnd (final).
#
# The bug this closes — silent bead reversion:
#   Bead writes (closing a bead, status changes) land only in the LOCAL embedded
#   Dolt DB (.beads/embeddeddolt, gitignored). The only path that carried them to
#   the remote "cold board" was a single best-effort push at SessionEnd whose
#   failure was swallowed (`|| true`, exit 0). In an ephemeral cloud container that
#   one push is fragile: if the container is reclaimed before SessionEnd fires, or
#   the push silently fails, the writes never reach the remote. The next cold
#   container then rehydrates (beads-bootstrap.sh) from the STALE remote and the
#   writes REVERT — beads snap back to their old open state with old timestamps.
#
#   Two hardening moves, hence two triggers:
#     • Stop       → mode "incremental": a cheap push-ONLY after every main-agent
#                    turn, so closes reach the remote within seconds — not held
#                    hostage until container teardown. This is the real fix: by the
#                    time any future container cold-starts, the remote already holds
#                    the closes, so the rehydrate has nothing stale to revert to.
#     • SessionEnd → mode "final": an authoritative reconcile — push-first with
#                    backoff retry; only on a non-fast-forward rejection do we
#                    pull+push; a persistent failure drops a DURABLE marker and logs
#                    loudly instead of vanishing.
#
#   Push-FIRST (not pull-first) is deliberate and matches the incident's lesson: the
#   live container holds the good state, so pulling a stale remote first can merge
#   the old "open" rows back over local closes (the observed revert). We only pull
#   when the remote has genuinely diverged and a push-first was rejected.
#
# Invariants (unchanged): web-only — a no-op unless CLAUDE_CODE_REMOTE=true, so
# local sessions keep the warn-only, human-in-the-loop stop-guard contract;
# beads-only — pushes the Dolt history, never git/code commits; non-fatal — every
# path exits 0, a lifecycle hook must never wedge.
set -uo pipefail

MODE="${1:-final}"   # "incremental" (Stop) | "final" (SessionEnd)

cat >/dev/null 2>&1   # consume stdin so the hook process doesn't hang on EOF
log() { printf '[beads-cloud-push] %s\n' "$*" >&2; }

# Web-only. Local sessions keep the warn-only guard's human-in-the-loop contract.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" 2>/dev/null || exit 0
command -v bd >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
[ -d "$ROOT/.beads" ] || exit 0

# The reachable Dolt remote is the git origin (the session proxy). Point bd at it
# transiently via env — never write the proxy URL into tracked .beads/config.yaml.
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
[ -n "$ORIGIN" ] || exit 0
export BD_SYNC_REMOTE="git+${ORIGIN}"

MARKER="$ROOT/.beads/.cloud-push-failed"

push_once() { bd dolt push >/dev/null 2>&1; }

# Push, retrying with exponential backoff (2s, 4s, 8s, 16s). 0 on success.
push_retry() {
  local delay=2 i
  for i in 1 2 3 4 5; do
    if push_once; then return 0; fi
    [ "$i" = 5 ] && break
    sleep "$delay"; delay=$((delay * 2))
  done
  return 1
}

# ── incremental (Stop) ──────────────────────────────────────────────────────────
# Cheap, push-ONLY, no-retry, best-effort. If the remote has diverged the push is
# rejected — fine: the next turn or the SessionEnd reconcile handles it. NEVER pull
# here; pulling a stale remote could revert just-made local closes.
if [ "$MODE" = "incremental" ]; then
  if push_once; then rm -f "$MARKER" 2>/dev/null || true; fi
  exit 0
fi

# ── final (SessionEnd) — authoritative reconcile ────────────────────────────────
log "persisting bead writes to the cloud remote…"

if push_retry; then
  log "bead writes pushed."
  rm -f "$MARKER" 2>/dev/null || true
  exit 0
fi

# Push still failing after retries — most likely the remote diverged (non-ff). Pull
# to reconcile (row-level merge keeps both sides' rows), then push again. Safe here
# precisely because a push-first already failed: we are not pre-empting local state.
log "push rejected — reconciling with remote (pull, then push)…"
bd dolt pull >/dev/null 2>&1 || true
if push_retry; then
  log "bead writes pushed after reconcile."
  rm -f "$MARKER" 2>/dev/null || true
  exit 0
fi

# Could not persist. Leave a durable, on-disk breadcrumb so the failure is NOT
# silent — stderr alone is invisible in an unattended container about to be
# reclaimed. The next SessionStart / health-check / human can recover from this.
{
  printf 'beads cloud push FAILED at session end.\n'
  printf 'The local .beads/embeddeddolt holds bead writes that never reached the remote;\n'
  printf 'they will REVERT when a fresh container rehydrates from the stale remote.\n'
  printf 'Recover with:\n'
  printf '  BD_SYNC_REMOTE="git+%s" bd dolt push\n' "$ORIGIN"
} > "$MARKER" 2>/dev/null || true
log "ERROR: could not push bead writes — wrote ${MARKER}. Writes are at risk of revert."
exit 0
