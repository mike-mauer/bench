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
#
# NOTE (Bench-cz6): BD_SYNC_REMOTE alone is NOT enough — `bd dolt push` (bd 1.1.0)
# does not read it, nor .beads/config.yaml's sync.remote. It pushes only to a
# remote registered in the local Dolt engine, which a fresh container does not
# have. SessionStart's beads-bootstrap registers one (Bench-4m0); this export
# stays because bd's other sync paths do honor it.
ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
[ -n "$ORIGIN" ] || exit 0
export BD_SYNC_REMOTE="git+${ORIGIN}"

MARKER="$ROOT/.beads/.cloud-push-failed"
# Session circuit breaker. Once a push fails for a reason retrying cannot fix, a
# further attempt costs real wall-clock — a blocked refs/dolt push takes ~45s to
# return its 403 — and Stop runs after EVERY turn. So record the verdict once and
# skip the channel for the rest of the session. SessionStart's beads-bootstrap
# clears this file, so each new session re-probes exactly once.
BLOCKED="$ROOT/.beads/.cloud-push-blocked"
PUSH_LAST_OUTPUT=""

# Push, and PROVE it happened. `bd dolt push` exits 0 when it did nothing —
# with no remote registered it prints "No remote is configured — skipping" and
# returns 0. Trusting $? alone made this hook report the silent no-op as success:
# it deleted the failure marker and logged "bead writes pushed." while the writes
# never left the container — exactly the revert this script exists to prevent
# (Bench-cz6). So inspect the output, never the exit status alone.
push_once() {
  # Bound it: a push that cannot complete must not hold a turn (Stop) or session
  # teardown (SessionEnd) open indefinitely. `timeout` is coreutils — absent on a
  # stock macOS, where we simply run unbounded rather than skip the push.
  local limit="${BENCH_PUSH_TIMEOUT:-60}"
  if command -v timeout >/dev/null 2>&1; then
    PUSH_LAST_OUTPUT="$(timeout "$limit" bd dolt push 2>&1)"
  else
    PUSH_LAST_OUTPUT="$(bd dolt push 2>&1)"
  fi
  local rc=$?
  # A killed push often leaves no usable output — say what happened, and mark it
  # as a timeout rather than letting it read as an unexplained failure.
  if [ "$rc" = 124 ]; then
    PUSH_LAST_OUTPUT="push exceeded ${limit}s and was cancelled (BENCH_PUSH_TIMEOUT)"
    return 1
  fi
  case "$PUSH_LAST_OUTPUT" in
    *"o remote is configured"*|*"No remotes configured"*) return 1 ;;
  esac
  return "$rc"
}

# A failure that retrying cannot fix: no remote at all, a remote URL bd rejects,
# or a transport the environment blocks (pushing the refs/dolt/* namespace 403s
# in some cloud containers, and Dolt's gRPC transport can't traverse an HTTP
# proxy). Spinning the backoff on these just delays session teardown by ~30s.
push_failure_is_permanent() {
  case "$PUSH_LAST_OUTPUT" in
    *"o remote is configured"*|*"No remotes configured"*) return 0 ;;
    *"Supported remote URLs"*|*"could not access dolt url"*) return 0 ;;
    *"403"*|*"unexpected disconnect"*|*"hung up unexpectedly"*) return 0 ;;
  esac
  return 1
}

# Trip the breaker: remember WHY, so SessionEnd can report it without paying for
# another doomed attempt.
trip_breaker() { printf '%s\n' "$(push_last_error)" > "$BLOCKED" 2>/dev/null || true; }
breaker_reason() { cat "$BLOCKED" 2>/dev/null; }

# Is the breaker's verdict a HARD one (no remote, blocked transport, bad URL), or
# merely a timeout? A timeout may be a slow-but-working link, so SessionEnd — the
# last chance to persist — still gets one bounded attempt; a hard verdict does not.
breaker_is_hard() {
  case "$(breaker_reason)" in
    *"exceeded"*) return 1 ;;
    "") return 1 ;;
    *) return 0 ;;
  esac
}

# One-line summary of the last push failure, for logs and the marker.
push_last_error() {
  local line
  line="$(printf '%s' "$PUSH_LAST_OUTPUT" | grep -iE 'error|fatal|no remote|refus|denied' | head -1)"
  [ -n "$line" ] || line="$(printf '%s' "$PUSH_LAST_OUTPUT" | grep -v '^[[:space:]]*$' | tail -1)"
  printf '%s' "${line:-unknown failure (bd dolt push produced no output)}"
}

# Push, retrying with exponential backoff (2s, 4s, 8s, 16s). 0 on success.
push_retry() {
  local delay=2 i
  for i in 1 2 3 4 5; do
    if push_once; then return 0; fi
    push_failure_is_permanent && return 1   # retrying cannot help — fail fast
    [ "$i" = 5 ] && break
    # (BENCH_TEST_FAST_RETRY collapses the backoff for the bats suite; the real
    # SessionEnd path always sleeps.)
    [ -n "${BENCH_TEST_FAST_RETRY:-}" ] || sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

# ── incremental (Stop) ──────────────────────────────────────────────────────────
# Cheap, push-ONLY, no-retry, best-effort. If the remote has diverged the push is
# rejected — fine: the next turn or the SessionEnd reconcile handles it. NEVER pull
# here; pulling a stale remote could revert just-made local closes.
if [ "$MODE" = "incremental" ]; then
  [ -e "$BLOCKED" ] && exit 0        # channel already proven broken this session
  if push_once; then
    rm -f "$MARKER" "$BLOCKED" 2>/dev/null || true
    exit 0
  fi
  # A permanently broken channel used to surface only at SessionEnd — too late in
  # a container that gets reclaimed first, and invisible while the agent keeps
  # writing beads it is about to lose. Say it ONCE, early, in the transcript, and
  # stop paying for the channel for the rest of the session.
  if push_failure_is_permanent || case "$PUSH_LAST_OUTPUT" in *"exceeded"*) true;; *) false;; esac; then
    trip_breaker
    log "WARNING: bead writes are NOT reaching the remote — $(push_last_error)"
    log "WARNING: they will be lost when this container is reclaimed. Persist them by committing"
    log "WARNING: a fresh export: bd export -o .beads/issues.jsonl && git add .beads && git commit"
  fi
  exit 0
fi

# ── final (SessionEnd) — authoritative reconcile ────────────────────────────────
log "persisting bead writes to the cloud remote…"

# The breaker already established this session that the channel cannot work. Skip
# straight to the report: another attempt would add ~45s to teardown and change
# nothing. (A container reclaimed mid-session never reaches this branch — which is
# why the incremental path warns in the transcript rather than only here.)
if [ -e "$BLOCKED" ] && breaker_is_hard; then
  PUSH_LAST_OUTPUT="$(breaker_reason)"
  log "push channel already established as unavailable this session — not retrying."
else
if push_retry; then
  log "bead writes pushed."
  rm -f "$MARKER" "$BLOCKED" 2>/dev/null || true
  exit 0
fi

# Push still failing after retries. If the channel itself is broken — no remote
# registered, a URL bd rejects, a blocked transport — a pull cannot help, and
# pulling a stale remote is precisely what reverts local closes. Reconcile ONLY
# for a divergence-shaped failure (non-fast-forward), which is what push-first
# was designed to handle.
if push_failure_is_permanent; then
  trip_breaker
  log "push channel unavailable — skipping the pull-reconcile ($(push_last_error))"
else
  log "push rejected — reconciling with remote (pull, then push)…"
  bd dolt pull >/dev/null 2>&1 || true
  if push_retry; then
    log "bead writes pushed after reconcile."
    rm -f "$MARKER" "$BLOCKED" 2>/dev/null || true
    exit 0
  fi
fi
fi   # end of the "breaker not tripped" branch

# Could not persist. Leave a durable, on-disk breadcrumb so the failure is NOT
# silent — stderr alone is invisible in an unattended container about to be
# reclaimed. The next SessionStart / health-check / human can recover from this.
{
  printf 'beads cloud push FAILED at session end.\n'
  printf 'The local .beads/embeddeddolt holds bead writes that never reached the remote;\n'
  printf 'they will REVERT when a fresh container rehydrates from the stale remote.\n'
  printf 'Last error: %s\n' "$(push_last_error)"
  printf 'Recover with EITHER a working Dolt push:\n'
  printf '  bd dolt remote add origin "git+%s"   # bd ignores BD_SYNC_REMOTE here\n' "${ORIGIN%.git}.git"
  printf '  bd dolt push\n'
  printf 'or, where the refs/dolt/* push channel is blocked, a committed export:\n'
  printf '  bd export -o .beads/issues.jsonl && git add .beads && git commit\n'
} > "$MARKER" 2>/dev/null || true
log "ERROR: could not push bead writes — $(push_last_error)"
log "ERROR: wrote ${MARKER}. Writes are at risk of revert; commit an export to save them."
exit 0
