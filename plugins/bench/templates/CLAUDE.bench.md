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

**Custom roles are part of the pipeline.** The pipeline is not limited to the built-in
roles. **Any agent in `.claude/agents/` is a routable role** — including project-defined
ones scaffolded by `/bench:new-agent`. Before routing, treat that directory as the source
of truth for which roles exist; slot each custom role in per its frontmatter `description`
and `## Routing` block. Do **not** add custom-role routing inside this managed block — it
is regenerated on `/bench:init`; the agent defs are the durable registration.

### Beads Issue Tracker
- Use `bd` for ALL task tracking — do NOT use ad-hoc TODO lists.
- `bd ready` (available work) · `bd show <id>` · `bd update <id> --claim` · `bd close <id>`.
- Run `bd prime` for command reference and session-close protocol (provided by the beads plugin).
- **Every role runs `bd` directly** against the shared project board with `--actor=<role>` —
  agents in worktrees reach the same board via git-common-dir discovery (verified bd 1.0.4). The
  orchestrator owns routing, integration, and the bounce cap, not courier duty (see the
  `bench-orchestrator` skill).

### Agent identity (actor attribution)
Every `bd` write must be attributed with `--actor` so activity shows the right agent and
the `engineer → qa → reviewer` chain renders as distinct events. Pass `--actor` **inline on
every `bd` write** — env vars don't survive across shell calls.
- Your own intake / inline-mode writes: `--actor=orchestrator`.
- Each pipeline role writes its own events with its own actor, e.g. the reviewer runs `bd close <id> --actor=reviewer` and the planner runs its `bd create`s with `--actor=planner`.

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
