#!/usr/bin/env bash
# scripts/worktree-reap.sh — worktree reaper + session hygiene.
#
# The orchestrator spawns code Workers into isolated git worktrees under
# .claude/worktrees/. When a Worker's tree is *locked* (the harness locks them so
# they survive a crash), `git worktree prune` will NOT reclaim it — so orphans
# accumulate. This reaper:
#   1. runs `git worktree prune` (reclaims unlocked, already-deleted trees);
#   2. force-removes stale .claude/worktrees/{agent-*,wf_*} trees whose branch is
#      merged into the integration branch OR whose recorded HEAD is unreachable;
#   3. NEVER removes a worktree currently in use (the tree holding $PWD, or main).
#
# Operates on the PROJECT (CLAUDE_PROJECT_DIR), not the plugin. Safe to run
# anywhere: a no-op when there is no worktrees dir, and only ever touches paths
# under .claude/worktrees. Wired to SessionStart via hooks.json.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$ROOT" 2>/dev/null || exit 0

command -v git >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

WT_DIR="$ROOT/.claude/worktrees"
log() { printf '[worktree-reap] %s\n' "$*" >&2; }

git worktree prune 2>/dev/null || true
[ -d "$WT_DIR" ] || { log "no .claude/worktrees — nothing to reap."; exit 0; }

# Resolve the integration branch to test "merged" against.
INTEGRATION=""
for ref in origin/main main origin/dev dev; do
  if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then INTEGRATION="$ref"; break; fi
done
[ -n "$INTEGRATION" ] || INTEGRATION="HEAD"

CURRENT_TREE="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
MAIN_TREE="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"

reaped=0 kept=0
wt_path="" wt_head="" wt_branch=""
flush() {
  [ -n "$wt_path" ] || return 0
  case "$wt_path" in
    "$WT_DIR"/agent-*|"$WT_DIR"/wf_*) : ;;   # only our isolated Worker trees
    *) return 0 ;;
  esac
  if [ "$wt_path" = "$CURRENT_TREE" ] || [ "$wt_path" = "$MAIN_TREE" ]; then return 0; fi

  local reason=""
  if [ -n "$wt_head" ] && ! git cat-file -e "${wt_head}^{commit}" 2>/dev/null; then
    reason="HEAD $wt_head unreachable"
  elif [ -n "$wt_branch" ] && git merge-base --is-ancestor "$wt_branch" "$INTEGRATION" 2>/dev/null; then
    reason="branch ${wt_branch#refs/heads/} merged into ${INTEGRATION}"
  fi

  if [ -n "$reason" ]; then
    if git worktree remove --force "$wt_path" 2>/dev/null; then
      log "reaped $(basename "$wt_path") ($reason)"; reaped=$((reaped+1))
    else
      rm -rf "$wt_path" 2>/dev/null && git worktree prune 2>/dev/null
      log "force-removed $(basename "$wt_path") ($reason)"; reaped=$((reaped+1))
    fi
  else
    kept=$((kept+1))
  fi
}

while IFS= read -r line; do
  case "$line" in
    worktree\ *) flush; wt_path="${line#worktree }"; wt_head="" wt_branch="" ;;
    HEAD\ *)     wt_head="${line#HEAD }" ;;
    branch\ *)   wt_branch="${line#branch }" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
flush

log "done — reaped ${reaped}, kept ${kept} in-use/active."
exit 0
