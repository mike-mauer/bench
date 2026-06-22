## Bench harness — operating rules

This project uses **Bench**, a beads-backed multi-agent orchestration harness. These
are the always-on rules for the main session. The full dispatch playbook lives in the
`bench-orchestrator` skill — invoke it before routing multi-step engineering work.

### Execution Mode (decide per request)
Before starting any substantive request, **make an explicit determination of how you'll
execute it, and state it in one line** before doing the work. Never silently default.
When in doubt, use the pipeline.

- **Orchestrated** (default for substantive work) — route through the agent pipeline:
  `planner` atomizes scope → `engineer` (or `data-eng` for data work, if installed)
  implements test-first on a **feature branch and opens a PR** → `qa` verifies
  user-observable behavior → `design-reviewer` gates any UI change (if installed) →
  `reviewer` does final correctness/security review. See the `bench-orchestrator` skill.
- **Inline** (allowed, but a stated choice) — do it directly in the main thread. Fine for:
  conversational answers, read-only investigation, single-file mechanical edits,
  copy/text changes, doc/config tweaks. Inline may also close beads.

**Triage on risk, not effort.** Default to orchestrated when the change touches the data
layer, auth/security, or spans multiple files; default to inline for low-risk single-file
edits, docs, and config. If you go inline on risky work, say so and offer the review gates.

### Beads Issue Tracker
- Use `bd` for ALL task tracking — do NOT use ad-hoc TODO lists.
- `bd ready` (available work) · `bd show <id>` · `bd update <id> --claim` · `bd close <id>`.
- Run `bd prime` for command reference and session-close protocol (provided by the beads plugin).
- **Only the main session runs `bd`.** Pipeline subagents run ZERO bd commands — they
  return their work as text and the orchestrator records it (see the `bench-orchestrator`
  skill for why: the embedded single-writer board loses or corrupts subagent writes).

### Agent identity (actor attribution)
Every `bd` write must be attributed with `--actor` so activity shows the right agent and
the `engineer → qa → reviewer` chain renders as distinct events. Pass `--actor` **inline on
every `bd` write** — env vars don't survive across shell calls.
- Your own intake / inline-mode writes: `--actor=orchestrator`.
- Relayed pipeline-role writes: the role that did the work, e.g. `bd close <id> --actor=reviewer`.

### Git Workflow
- **Commit frequently** — small, focused commits after each logical change.
- **Commit before large changes** — always commit working state before refactors or risky
  multi-file changes so there's a clean rollback point.
- Ship via **feature branch → PR → integration branch**; don't push directly to the
  integration branch from pipeline work.

### Session Completion
When ending a work session, work is NOT complete until `git push` succeeds:
1. File beads for remaining work.
2. Run quality gates on changed code (tests, lint, build).
3. Update bead statuses; close finished work.
4. **Push to remote** (`git pull --rebase` → `git push` → confirm `git status` is clean).
5. Clean up stashes/branches and reap orphaned worktrees.
