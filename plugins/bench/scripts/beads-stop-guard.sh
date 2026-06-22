#!/usr/bin/env bash
# scripts/beads-stop-guard.sh — SessionEnd hook: warn when stranded work exists.
#
# Wired into hooks.json under SessionEnd. WARN-ONLY — never commits, pushes, or
# blocks; every exit is 0. It exists to remind a human running the session-close
# protocol that uncommitted or unpushed work is about to be left behind.
#
# Guard logic:
#   1. Not a git repo? Exit 0 silently.
#   2. Inside a linked worktree (git-dir ≠ git-common-dir)? Exit 0 silently —
#      Workers run in .claude/worktrees/<id> and must never trigger the guard.
#   3. Otherwise: print a warning listing uncommitted/unpushed work, then exit 0.
set +e

# Consume stdin so the hook process doesn't hang waiting for EOF.
cat >/dev/null 2>&1

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Skip inside a linked worktree (git-dir points to .git/worktrees/<id>, while
# git-common-dir still points to the canonical .git; equal in the main checkout).
git_dir="$(git rev-parse --git-dir 2>/dev/null)"
git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
git_dir_real="$(cd "${git_dir}" 2>/dev/null && pwd -P 2>/dev/null || echo "${git_dir}")"
git_common_dir_real="$(cd "${git_common_dir}" 2>/dev/null && pwd -P 2>/dev/null || echo "${git_common_dir}")"
[ "${git_dir_real}" != "${git_common_dir_real}" ] && exit 0

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
problems=""

# 1. Uncommitted changes (tracked + untracked, excluding ignored).
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  problems="${problems}  • Uncommitted changes in the working tree (git add + commit).\n"
fi

# 2. Committed-but-unpushed work, when the branch has a configured upstream.
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null)"
  if [ -n "${ahead}" ] && [ "${ahead}" -gt 0 ]; then
    problems="${problems}  • ${ahead} commit(s) not pushed to the upstream branch (git push).\n"
  fi
fi

if [ -n "${problems}" ]; then
  printf 'Session-end guard [warn-only]: stranded work detected on branch %s.\n%b\nRun the session-close protocol before ending.\n' \
    "${branch}" "${problems}" >&2
fi
exit 0
