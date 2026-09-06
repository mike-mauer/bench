# Evaluation: from Bench to a software factory

**Status:** evaluation / proposal (2026-09-06)
**Question:** Bench works locally but not in the cloud, and beads causes merge conflicts and
trips over itself. Starting from first principles, what is the best way to get cloud access,
portability, a detailed dependency-aware planner, mandatory TDD, a smart multi-model
orchestrator, an implement→review loop that reruns until review passes, adversarial QA, and
ultimately Sentry-triggered self-healing with no human in the loop?

**Short answer:** keep the *ideas* in Bench (the role definitions, the adversarial gates, the
handoff contract, the bounce cap, TDD-from-history), and throw away the *plumbing* (beads,
Dolt, worktree guards, cloud-push, bootstrap). Every plumbing problem Bench has spent its
last ten PRs fighting is a consequence of one decision: keeping work-tracking state in a
local database inside an ephemeral container. Replace it with GitHub Issues as the state
store, Claude Code Routines and the GitHub Action as the trigger surface, and a saved
dynamic Workflow as the orchestrator. Nothing off the shelf covers the whole loop, but the
first-party pieces now cover all the parts Bench had to hand-build, and the remaining
"factory" layer is a few hundred lines of prompts and one workflow script.

---

## 1. What Bench is, measured

| Area | Lines | Share of repo | What it is |
|---|---|---|---|
| `scripts/` | 1,741 | 37% | Hook scripts. **1,381 lines (79%) are beads/Dolt plumbing.** |
| `tests/` | 1,673 | 36% | bats tests. Nearly all test the beads/Dolt plumbing. |
| `agents/` + `skills/` | 875 | 19% | The role prompts and the orchestrator playbook. **This is the value.** |
| `commands/` + `templates/` | 454 | 10% | init / doctor / new-agent and the managed CLAUDE.md block. |

The board tells the same story. Of 18 open or in-progress beads, **11 are about beads itself**
in cloud containers: the push transport for `refs/dolt/*` is 403'd by the cloud proxy
(Bench-g47), the Dolt remote is per-container state (Bench-4m0), `bd dolt push` silently
no-ops (Bench-cz6), the detached install races the first `bd` call (Bench-3op), stale
`issues.jsonl` reverts the local board on worktree-add (Bench-a40), and so on. The commit
history since 2026-08-30 is entirely cloud-persistence hardening. The harness's backlog is
dominated by its own tracker.

### Direct evidence from this session

This evaluation was written in a Claude Code cloud session on this very repo, which commits
the `.claude/settings.json` web-enablement config that README says makes Bench work on the
web. Observed:

- No `planner` / `engineer` / `qa` / `reviewer` subagent types were registered. Only the
  built-in agent types were available.
- No `bd` binary anywhere on disk. No `.beads/embeddeddolt`. No SessionStart hook output.
- `~/.claude/plugins/` contained only user-synced state, no marketplace plugins.

So in the cloud, with the documented fix applied, the harness is fully offline. That matches
the complaint exactly, and it is not a bug you can patch from inside the plugin: it depends on
whether the web runtime installs marketplace plugins from repo settings at all, which is
outside your control.

### Why beads fights you (root cause, not symptoms)

Beads stores the board in a Dolt database that is gitignored, and syncs it over a custom git
ref namespace. That design is right for Gas Town (one long-lived host, a `dolt sql-server`,
160 agents) and wrong for the shape you actually run: **many short-lived containers, each
starting from a clone, with a proxy that blocks the sync ref.** Every mitigation Bench added
(push-first, circuit breaker, union-merge on the JSONL export, chmod, remote rewriting to
`git+https`) is correct engineering aimed at a problem that only exists because the state
lives in the wrong place. Upstream agrees the multi-machine case is fragile: beads issues
#2466 (recurring metadata conflicts multi-machine), #2474 (server-mode pull corruption),
#4074 (`issues.jsonl` rebase conflicts even with a remote Dolt) are all from 2026.

The `docs/server-mode-migration.md` proposal would add a per-container `dolt sql-server` to
fix concurrency. It does not fix the blocked push channel, and it re-adds the ops burden that
beads 1.0 explicitly removed as "a regression for standalone users." Not recommended.

---

## 2. First principles: what a software factory actually needs

Strip the tooling away and there are five components. For each, the question is "where does
the state live and who can reach it from a fresh container over HTTPS?"

| Component | Requirement | Bench today | Where it should live |
|---|---|---|---|
| **1. Work queue** | Durable, conflict-free, dependency-aware, reachable by API from anywhere, every event attributed | Beads (local DB, custom sync ref, per-container state) | **GitHub Issues** (native `blocked by` dependencies GA since Aug 2025, sub-issues, labels, webhooks, MCP tools already loaded in every Claude Code session) |
| **2. Trigger** | Something external starts a fresh worker when work appears (Sentry alert, issue labeled, cron sweep) | None. A human opens a session. | **Routines** (`/fire` HTTP API, cron, GitHub PR/release events) and **claude-code-action** on `issues: labeled` |
| **3. Execution unit** | One issue → one isolated environment → one branch → one PR with tests | Subagent in a git worktree inside a shared session; three guard hooks to keep it from wrecking the parent tree | **One cloud session per issue.** Isolation is the container. Worktree guards become unnecessary. |
| **4. Gates + loop** | Machine-checkable: tests exist and pass, TDD order verified, adversarial QA, security review; loop reruns until green with a cap and an escalation path | Role prompts (good) + orchestrator playbook (good) + bounce cap enforced by the human-driven main session | **Same role prompts**, driven by a saved **dynamic Workflow** (`pipeline()`, per-agent model, max rounds), plus first-party **Code Review** and **Auto-fix PRs** on the PR itself |
| **5. Closure + feedback** | Merge closes the issue, resolves the Sentry issue, a regression reverts | Reviewer runs `bd close` | `Closes #N` / `Fixes SENTRY-ID` in the PR; Sentry's GitHub integration resolves on merge; a release-health Routine reverts on regression |

The key observation: **components 1, 2, 3 and most of 4 are now first-party.** In 2025 they
were not, and hand-building them with beads and worktrees was a reasonable bet. In September
2026 the bet has been called. What is *not* off the shelf, and where Bench's real IP sits, is
the opinionated pipeline inside component 4: a planner that writes red-test acceptance
criteria and dependency edges, an engineer that must commit the red test before the green
implementation, a QA role that runs the app trying to break it, and a reviewer that verifies
TDD from history and owns security. Keep all of that.

---

## 3. Options

### Option A: keep Bench, finish the beads cloud work
Fix Bench-g47/4m0/cz6/3op/a40, or do the server-mode migration.
**No.** The push channel is blocked by the environment, not by your code; the plugin does not
load in the cloud at all; and every hour spent here is spent on a tracker, not a factory.

### Option B: replace the whole thing with a vendor product

| Product | Sentry → PR | Issue → PR | Planner / TDD / adversarial QA | Model choice | Fit |
|---|---|---|---|---|---|
| **Sentry Seer + Claude Managed Agent** | Yes, native and hands-off (Seer actionability filter → Managed Agent in your Claude org → PR). Verified in sentry-docs. | No | Black box. You get a PR; you do not control the process. | Opus 5 → Opus 4.8 → Sonnet 5 fallback | **Strong for the production-error lane only.** Pair with your own gates on the PR. |
| **Cursor Automations / Cloud Agents** | Yes (Sentry trigger → cloud agent → PR) | Yes | None built in | Any | Vendor lock; no process control. |
| **Devin Auto-Triage** | Yes (Sentry/Datadog/PagerDuty webhooks) | Linear delegation | Self-reviews own PRs | Managed | API is Teams/Enterprise only. |
| **GitHub Agent HQ (assign issue to Claude/Codex/Copilot)** | No | Yes, one click | None | Fixed per agent | Cheap issue → draft PR; Copilot cannot even mark its PR ready by design. |
| **Google Jules** | No | Label `jules` | "Critic" agent reviews patches | Gemini only | Wrong model stack. |
| **OpenAI Symphony** | No | Linear polling | Proof-of-work = CI status; humans land | Codex | Good spec, wrong stack, Linear-centric. |
| **Gas Town** | No | beads | Merge queue with gates | Claude | Requires beads + Dolt + tmux + a long-lived host. The exact problem. |
| **Ruflo (ex claude-flow)** | — | — | Claims everything | — | Independent audit (Apr 2026) found ~10 of 300 MCP tools functional. Avoid. |
| **ccswarm** | No | `--from-issue` | plan → consensus → implement → review → fix | Claude + Codex | Closest to your spec; ~150 stars, one maintainer. |

Also note the reported April 2026 policy that Claude Pro/Max OAuth tokens may not be used in
third-party harnesses. First-party surfaces (Claude Code CLI, web, Routines, the GitHub Action)
remain subscription-eligible; anything in the open-source list above needs API-key billing.
That alone argues for staying on first-party surfaces.

**Verdict:** nothing off the shelf gives you planner + TDD + adversarial QA + review loop with
model selection. Seer → Managed Agent is worth turning on for the Sentry lane because it is
zero code, but it should feed *into* your gates, not replace them.

### Option C (recommended): Bench v2, a thin layer on first-party primitives

Keep the name, keep the plugin packaging, keep the four role prompts. Replace the plumbing.

---

## 4. Bench v2 design

### 4.1 State: GitHub Issues

- **One issue = one bead.** The planner creates sub-issues under an epic issue and wires
  `blocked by` edges. `bd ready` becomes "open issues with no open blockers and label
  `factory:ready`" (one GraphQL query, or the `search_issues` MCP tool already in-session).
- **Handoffs = issue comments** in the existing `## Handoff from <role>` format. Everything is
  posted by one GitHub App identity, so the role name in the heading carries attribution. The
  `--actor` guard hook and `BEADS_ACTOR` plumbing disappear.
- **Gate = label.** `gate:engineer`, `gate:qa`, `gate:review`, `needs-human`, and `round:N`.
  That replaces the "assignee is the current gate" convention and the ROUND counting from
  comments.
- **Spec = issue body**, using the planner's existing template (Source, red-test acceptance
  list, Out of scope, Notes for the builder). The self-sufficiency rule stays: a worker starts
  from the issue alone.
- **Migration:** a ~50-line script converts `.beads/issues.jsonl` (31 rows) into issues with
  labels and dependency edges. Then delete `.beads/`.

Linear is the alternative if you want a delegation UI and its agent-session API. It has no
native Claude Code agent (you would bridge via Routines or Cyrus), so GitHub Issues is the
lower-friction default.

### 4.2 Triggers: three lanes into the same pipeline

1. **Issue lane.** A GitHub Actions workflow on `issues: [labeled]` with `label_trigger:
   factory:ready`. Two ways to run the worker:
   - `anthropics/claude-code-action@v1` in automation mode (runs on the Actions runner,
     token-billed, Claude authenticates as the GitHub App so CI runs on its commits), or
   - a five-line `curl` that hits a Routine's `/fire` endpoint with the issue number in `text`,
     so the work runs in a Claude Code cloud session (subscription-billed, daily run cap).
   Routines' own GitHub trigger covers only PR and release events, not issues, so this small
   Action is the bridge either way.
2. **Sentry lane.** A Sentry issue-alert rule with a webhook action → the same Routine `/fire`
   with the Sentry issue ID. The session reads the issue through the Sentry MCP server, files a
   GitHub issue with the stack trace and a red-test acceptance criterion ("a test that
   reproduces this exact error signature fails before the fix"), then runs the pipeline.
   Optionally turn on Seer → Claude Managed Agent in parallel as a zero-code baseline and
   compare PR quality.
3. **Sweep lane.** A cron Routine every N hours: find `factory:ready` issues with no open
   blockers and no active PR, fire one session each. This is the "self-scheduling" property
   Gas Town gets from its daemon, with no daemon.

### 4.3 Orchestration: one saved Workflow

Bench's orchestrator playbook becomes `.claude/workflows/factory.js`, a dynamic Workflow
script (the `ultracode` mechanism). The Workflow tool is available in cloud sessions, supports
per-agent model selection, `pipeline()` for staged fan-out, structured output schemas, and
resume from a run id. Sketch:

```
plan     = agent(planner,  {model: 'opus'})        // if the issue is an epic: files sub-issues + blocked-by, returns START
impl     = agent(engineer, {model: 'sonnet'})      // red commit → green commit → PR
loop (max 2 rounds per gate):
  qa     = agent(qa,       {model: 'sonnet'})      // runs the app adversarially → pass|fail
  if fail → engineer fix round, continue
  review = agent(reviewer, {model: 'opus'})        // TDD-from-history, security → pass|fail
  if fail → engineer fix round, continue
  break
if still failing → label needs-human, comment summary, stop
```

Only the top session can pick models and run agents in parallel, which is why Bench put the
orchestrator in the main session. That is still true; the workflow *is* the main session's
script. The bounce cap becomes a loop bound instead of a rule the human must remember.

Per-issue sessions mean every code worker gets its own container, so `isolation: "worktree"`
and the three guard hooks (`guard-checkout`, `guard-bd-actor`, `guard-task-tools`) are no
longer needed. If you still want parallel workers *inside* one session for large epics,
the Workflow supports 16 concurrent agents and subagents still support `isolation: worktree`.

### 4.4 Gates on the PR (first-party, no code)

- **CI is required**, and the CI job must fail if the diff adds production code without a test
  commit that predates it (a 20-line script over `git log` implementing the reviewer's rule 7,
  so the gate is mechanical, not just prompted).
- **Claude Code Review** as a required check, with a severity threshold as the merge gate.
- **Auto-fix PRs** re-runs on CI failure and review comments until green. This is the
  "implementation → review loop that reruns until review passes" for the PR stage.
- **Ultrareview** in CI (`claude ultrareview --json`) as a second, independent bug pass if you
  want two models looking at every diff.

### 4.5 Merge and self-healing policy (be honest about the frontier)

No credible published case ships Sentry → PR → production with zero human review. Sentry's own
"Seer runs unattended every 4 hours" story still has a human merging every PR, and Copilot's
cloud agent cannot mark its own PR ready by design. The pragmatic ladder:

1. **Now:** everything above, human on the merge button. Measure: time-to-PR, rounds per
   issue, and the share of PRs merged without human edits.
2. **Next:** `gh pr merge --auto` for a narrow, explicitly allow-listed class: Sentry-sourced
   fixes where the red test reproduces the exact error signature, diff under N files, no
   migrations, no auth paths, Code Review severity zero, CI green. Ship behind a canary.
3. **Then:** a release-health Routine that watches the Sentry issue after deploy and reverts
   the PR if the error recurs or the error rate regresses. That is the "self-healing" loop,
   and the revert path is what makes auto-merge safe enough to widen.

**Security note for the Sentry lane.** Stack traces and error messages are attacker-controlled
input (the "agentjacking" prompt-injection attack against Sentry MCP was public in 2026). The
Sentry-lane prompt must state that error payloads are data, never instructions; the worker
should get a minimal tool set and no production secrets; and the PR should never auto-merge
if the diff touches anything the stack trace did not point at.

### 4.6 What is deleted and what survives

| Delete | Keep (edited) | New |
|---|---|---|
| `install-bd.sh`, `beads-bootstrap.sh`, `beads-cloud-push.sh`, `beads-stop-guard.sh` | `agents/*.md` (strip every `bd` line; read the issue via MCP/`gh`; post handoffs as comments; roughly half the length) | `.claude/workflows/factory.js` |
| `guard-bd-actor.sh`, `guard-checkout.sh`, `guard-task-tools.sh`, `worktree-reap.sh` | `skills/bench-orchestrator` (becomes the design note behind the workflow) | `.github/workflows/factory-dispatch.yml` (label → fire) |
| `beads-health-check` skill, `docs/server-mode-migration.md` | `commands/init.md` (much smaller: labels, workflow, Action, CLAUDE.md block), `doctor.md`, `new-agent.md` | `scripts/tdd-order-check.sh` for CI |
| `.beads/`, `.beads/hooks/*`, the beads plugin dependency | `templates/CLAUDE.bench.md` (drop the beads section) | `scripts/migrate-beads-to-issues.py` (one-off) |
| ~1,600 lines of bats tests for the above | `claudemd-drift-check.sh`, `bench-hash.sh` | Sentry-lane prompt for the Routine |

Rough size after: about a quarter of today's line count, with no per-machine state.

---

## 5. Phased plan

| Phase | Work | Exit criterion |
|---|---|---|
| **0. Cut over the tracker** (~1 day) | Migrate the 31 beads to GitHub Issues with labels and `blocked by`. Remove beads hooks and dependency. | `bd` no longer referenced anywhere; open issues visible on GitHub with dependency badges. |
| **1. Port the pipeline** (~2 days) | Rewrite the four agents without `bd`. Write `factory.js`. Run it interactively on one real issue in a cloud session. | One issue goes planner → engineer → qa → reviewer → PR with red/green commits, no human steps in between. |
| **2. Wire triggers and PR gates** (~1 day) | Label → fire Action. Code Review + Auto-fix on the repo. TDD-order CI check. | Labeling an issue `factory:ready` produces a green PR with review findings addressed, unattended. |
| **3. Sentry lane** (~2 days) | Alert webhook → Routine. Sentry MCP read. Red test must reproduce the error. Turn on Seer → Managed Agent as a comparison baseline. | A seeded production error yields a PR whose test fails on `main` and passes on the branch. |
| **4. Earn auto-merge** (ongoing) | Collect the metrics from 4.5. Allow-list the narrow class. Add the release-health revert Routine. | Auto-merged fixes have a revert path that has been exercised at least once on purpose. |

Phases 0 through 2 replace what Bench does today with something that works in the cloud.
Phases 3 and 4 are the factory.

---

## 6. Things to decide (not defaults)

- **GitHub Issues vs Linear** as the queue. **DECIDED: GitHub Issues.** The deciding reason:
  every gate in the pipeline (`qa`, `design-reviewer`, `reviewer`) lands its verdict on the
  PR, and the PR already lives in GitHub — keeping the work queue in the same system means
  an issue, its dependency edges, its labels, and the PR that closes it are one graph with no
  sync layer between two systems that would otherwise need to agree on state. Revisit Linear
  when a human needs to work the queue daily from Linear's UI badly enough to justify running
  a bridge (Routines or Cyrus) to keep it in step with GitHub.
- **Action runner vs Routine `/fire`** as the execution host for the issue lane. Routine keeps
  execution in Claude Code cloud on subscription billing but is a research preview with a
  daily run cap; the Action is GA but token-billed and runs on Actions minutes. Start with the
  Routine, keep the Action as the fallback.
- **Seer → Managed Agent on or off.** Recommended on, as a baseline to beat, not as the
  system of record.
- **Keep the plugin/marketplace packaging?** Yes for the agents, workflow, and init/doctor
  commands. Given plugins did not load in this cloud session, `/bench:init` should also copy
  the agents and workflow into the consuming repo's `.claude/` so the cloud does not depend on
  marketplace loading at all.

---

## Sources checked

Claude Code docs: workflows, sub-agents, agent-teams, routines, github-actions, code-review,
ultrareview, plugins, hooks-guide, claude-code-on-the-web. Managed Agents overview on
platform.claude.com. `getsentry/sentry-docs` coding-agents integration pages (Claude, Copilot).
GitHub docs on issue dependencies. Beads issues #2466, #2474, #2573, #4074. Ruflo audit gist
(Apr 2026). Repos: gastownhall/gastown, openai/symphony, nwiizo/ccswarm,
google-labs-code/jules-action, Factory-AI/droid-action, OpenHands/OpenHands. Vendor pricing and
several Sentry/Cursor/Devin pages were reachable only through search snippets from this
container and are marked as such in the research notes.
