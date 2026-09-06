# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Work tracking: GitHub Issues

This project tracks work in GitHub Issues, not a local database. One issue = one unit of
work; labels carry pipeline state (`factory:ready`, `gate:<role>`, `factory:approved`,
`needs-human`); handoffs are issue comments headed `## Handoff from <role>`. The normative
spec is `docs/factory-protocol.md` — read it before touching the pipeline, the agent
prompts, or the workflow script.

## Build & Test

This repo is the source of the Bench plugin — there is no app to build. Quality gates:

```bash
claude plugin validate ./plugins/bench --strict         # plugin manifest/structure validation
shellcheck plugins/bench/scripts/*.sh                    # lint all shell scripts
bats tests/                                               # script tests (tests/ is landing on a parallel branch)
scripts/tdd-order-check.sh <base>..<head>                 # verify red-test-before-green commit order
```

## Architecture Overview

This repo is a Claude Code plugin **marketplace** serving a single plugin: `.claude-plugin/marketplace.json` points at `./plugins/bench`. Inside `plugins/bench/`, `agents/` holds the core pipeline roles (planner, engineer, qa, reviewer) and `agents-optional/` the opt-in specialists (data-eng, design-reviewer) that `/bench:init --with` copies into a consuming project. `workflows/factory.js` is the saved dynamic Workflow that drives the per-issue loop end to end (triage → plan → build → gate loop → escalate). `skills/bench-orchestrator` carries the dispatch playbook. `commands/` holds the `/bench:*` slash commands (`init`, `doctor`, `new-agent`); `/bench:init` copies the agents and the workflow into a consuming project's `.claude/`, creates the GitHub labels from `docs/factory-protocol.md` §3, and installs a dispatch lane (`templates/factory-dispatch-action.yml` or `-routine.yml`) so a cloud session never depends on marketplace plugin loading. `hooks/hooks.json` wires only a SessionStart CLAUDE.md drift check (`scripts/claudemd-drift-check.sh`) — there is no bd install, worktree reaper, session-end guard, or cloud-push hook in v2. `scripts/` also carries `bench-hash.sh` (the managed-block hash), `gh-issue-dep.sh` (native `blocked by` edges), `factory-ready.sh` (dispatch readiness query), `tdd-order-check.sh` (CI gate), and `migrate-beads-to-issues.py` (one-off v1→v2 migration). See `docs/factory-protocol.md` §14 for the full layout.

## Conventions & Patterns

- **Hook scripts are best-effort:** every code path exits 0 — a hook must never block a session. They use `set -uo pipefail` (never `-e`) and log through a `log()` helper that prefixes each line (e.g. `[claudemd-drift-check] …`).
- **Managed CLAUDE.md block:** the orchestrator block shipped in `templates/CLAUDE.bench.md` is versioned by an 8-char content hash (`<!-- BEGIN BENCH v:N hash:XXXX -->`, computed by `scripts/bench-hash.sh`) and managed by `/bench:init`; the drift-check hook warns when a project's copy goes stale.

<!-- BEGIN BENCH v:2 hash:11f6a0a6 -->
## Bench harness — operating rules

This project uses **Bench**, a multi-agent software factory built on GitHub Issues. These
are the always-on rules for the main session. The full dispatch playbook lives in the
`bench-orchestrator` skill, and the normative contract in `docs/factory-protocol.md`.
**Invoke the skill before**: dispatching any work beyond a single-file edit, touching
multiple roles, or spawning any Worker.

### Hard rails
- The issue is the context and the record — spec on the issue body, pipeline state in its
  comments, only runtime facts in a Worker's prompt.
- Exactly one `gate:*` label at a time; the role handing off moves it.
- Builders never push to the integration branch and never merge.
- Only the `reviewer` marks an issue `factory:approved`; the PR merge closes it.
- Hand-dispatched Workers share this session's working tree — spawn any builder, or any
  gate that checks out a branch, with `isolation: worktree`. Never `checkout`/`switch` in
  the shared tree. (The `factory` workflow's own Agent-tool calls already set this; it only
  needs stating for dispatch you do yourself.)

**After context compaction**, re-invoke `bench-orchestrator` before the next dispatch —
compaction can drop the routing state this block depends on.

### Execution Mode (decide per request)
Before starting any substantive request, **make an explicit determination of how you'll
execute it, and state it in one line** before doing the work. Never silently default.
When in doubt, use the pipeline.

- **Orchestrated** (default for substantive work) — run the saved workflow
  (`Workflow` with `.claude/workflows/factory.js` and `args: { issue: <n> }`), or dispatch
  the roles yourself with the Agent tool: `planner` atomizes scope → `engineer` (or
  `data-eng` for data work, if installed) implements test-first on a **feature branch and
  opens a draft PR** → `qa` verifies user-observable behavior → `design-reviewer` gates any
  UI change (if installed) → `reviewer` does final correctness/security review. See the
  `bench-orchestrator` skill.
- **Inline** (allowed, but a stated choice) — do it directly in the main thread. Fine for:
  conversational answers, read-only investigation, single-file mechanical edits,
  copy/text changes, doc/config tweaks. Inline may close an issue only when no PR exists
  for it (wontfix / duplicate / already-shipped); otherwise the PR merge closes it.

**Autonomy.** Proceed on routine routing decisions — next gate, model choice, branch
naming — and note them in-line; ask only for scope changes, destructive actions, or a
bounce-cap escalation.

**Triage on risk, not effort.** Default to orchestrated when the change touches the data
layer, auth/security, or spans multiple files; default to inline for low-risk single-file
edits, docs, and config. If you go inline on risky work, say so and offer the review gates.
MUST-orchestrate examples: a schema/migration change; any change that will need
engineer → qa → reviewer sign-off; anything that opens a PR from pipeline work.

**Delegate, don't iterate serially.** When work fans out across independent items
(several unrelated issues, or one issue splitting into parallel-safe pieces), dispatch
Workers for each rather than working through them one at a time in-thread.

**Custom roles are part of the pipeline.** The pipeline is not limited to the built-in
roles. **Any agent in `.claude/agents/` is a routable role** — including project-defined
ones scaffolded by `/bench:new-agent`. Before routing, treat that directory as the source
of truth for which roles exist; slot each custom role in per its frontmatter `description`
and `## Routing` block. Do **not** add custom-role routing inside this managed block — it
is regenerated on `/bench:init`; the agent defs are the durable registration.

### Work tracking: GitHub Issues
- One GitHub issue = one unit of work. File one before acting on any actionable item; the
  built-in task tools are fine for in-session scratch but are **not** the record.
- Read with `gh issue view <n> --comments` (or the GitHub MCP `issue_read`); a Worker
  starts from the issue and its comments alone — nothing gets re-pasted into prompts.
- Labels carry the state: `factory:ready` (dispatchable), `factory:in-progress` (owned),
  `gate:<role>` (current gate), `factory:approved` (reviewer passed), `needs-human`
  (escalated), plus `lane:*`, `priority:p0`–`p4`, `type:epic`.
- Handoffs are issue comments headed `## Handoff from <role>` — the heading is the
  attribution; every role posts its own before it terminates.
- Ready = open ∧ `factory:ready` ∧ no `factory:in-progress` ∧ no `needs-human` ∧ not
  `type:epic` ∧ every blocker closed. `scripts/factory-ready.sh` computes it. Epics are
  never dispatched to a builder directly — split them into sub-issues first.

### Git Workflow
- **Commit frequently** — small, focused commits after each logical change.
- **Commit before large changes** — always commit working state before refactors or risky
  multi-file changes so there's a clean rollback point.
- The red test is its own commit **before** any production change: `test(#<n>): …` then
  `feat|fix(#<n>): …`. CI enforces the order.
- Ship via **feature branch (`factory/<n>-<slug>`) → draft PR → integration branch**; the
  PR body carries `Closes #<n>`. Don't push directly to the integration branch from
  pipeline work.

### Session Completion
When ending a work session:
1. File issues for remaining work.
2. Run quality gates on changed code (tests, lint, build).
3. Update labels to reflect reality; nothing left `factory:in-progress` that no session
   owns, anything parked is `needs-human` with a comment saying why.
4. **Commit locally** — leave changed work in small, focused commits (see Git Workflow).
5. **Push / open PRs only with explicit authority.** Conservative is the default: report
   what's ready and the exact commands (`git push`, `gh pr create …`), and run them only if
   the user/orchestrator granted authority this session or the project has explicitly
   opted in.
6. Clean up stale branches.
<!-- END BENCH -->
