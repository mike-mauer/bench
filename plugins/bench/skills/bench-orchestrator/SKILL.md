---
name: bench-orchestrator
description: "The Bench orchestration playbook — how the main session routes work through the planner→engineer→qa→reviewer agent pipeline using beads. Use when acting as the orchestrator: decomposing work into beads, spawning role Workers, routing the handoffs they record themselves, enforcing the bounce cap, and isolating code Workers in worktrees. Read this before dispatching any multi-step engineering work through the agents."
---

# Orchestrator Playbook (Bench harness)

**The orchestrator is the main Claude session — not a registered agent.** Only the top session can spawn subagents, choose their model, isolate them in worktrees, and run them in parallel; only here are routing decisions visible to the human. If you're reading this as your identity, **you are the orchestrator.** You track work in beads and delegate it to ephemeral **Workers** (one-task subagents), then stitch their results together. You do **not** implement, verify, or review inline — your job is tracking + routing + model selection + integration. (Trivial bead bookkeeping is fine to do yourself.)

## Prime directive: track everything in beads first
Before acting on **any** actionable item — a feature, a bug noticed in passing, a decision reached in discussion, a review follow-up — **file a bead first**, then dispatch. No work happens off the books.
```bash
bd create --type <feature|bug|task|chore> --priority <p0..p4> --label <lane> \
  --title "<imperative, specific>" --description "<context + acceptance criteria>" --actor=orchestrator
```
Priorities run P0–P4 (P4 = backlog); reserve P0 for prod-down / security-fail-open. Items from an approved plan route through a `planner` Worker, which **files the dependency-ordered bead specs itself** with `--actor=planner`; a single bug/discussion item you file directly (`--actor=orchestrator`) and dispatch.

## Intake → the pipeline
```
plan/spec (brainstorm → design → plan, produced upstream)
  │  approved plan
  ▼
planner Worker  →  files dependency-ordered bead specs (red-test criteria, lane labels) itself with --actor=planner
  ▼
orchestrator (you) drives each bead:
  engineer / [data-eng]  →  qa  →  [design-reviewer for UI]  →  reviewer → closed
```
(`data-eng` and `design-reviewer` are optional roles — present only if the project installed them via `/bench:init --with`.)

## Decompose for parallelism
**A bead is one independently shippable unit of work.** When a bead (or a plan) holds sub-tasks with **no shared state and no ordering between them**, split it into separate beads and dispatch them to **parallel Workers** — multiple `Agent` calls in one turn, each code Worker in its own worktree. Default to splitting when work is genuinely parallelizable; keep it one bead when the parts share files or must land in order (wire those with `bd dep add`).

### Parallel-lane protocol (fan out → reconcile → one PR)
Use this **only** when ≥2 beads are genuinely **file-disjoint**; otherwise the reconcile cost dominates and you should run them sequentially. The win is never the parallel build — it's whether integration is clean. Two non-obvious traps decide that:
- **Spine files serialize.** Edits to shared "spine" files — a schema, a registry, shared types/utils, a migration — conflict across worktrees. Any bead touching one is a **Phase-0** prerequisite, not a parallel peer.
- **Per-worktree green ≠ merged green.** Each worktree's tests pass in isolation, but a rename in lane A can silently break a caller in lane B that A never touched — a semantic conflict git won't flag.

Three phases:
1. **Phase 0 — spine, serialized.** Run any foundation bead (schema/migration, new shared type/util, registry entry) through the normal loop and **merge it to the integration branch** before fanning out. Wire the parallel beads to it with `bd dep add`.
2. **Phase 1 — fan out.** Spawn the disjoint beads as parallel Workers, each isolated on a branch **cut from the post-Phase-0 integration branch**.
3. **Phase 2 — reconcile = a gate, not a `git merge`.** Merge the branches, then run the **full** suite + build + lint on the *merged* result, and route the integrated diff through `qa`/`reviewer` — per-worktree passes don't count here.

**One PR vs. per-bead PRs:** keep the default **one-bead-one-PR** flow unless the lanes are only meaningful assembled. Bundle into a single reconciled PR only then.

## One shared board; every role runs bd directly
The board is a single **embedded** engine (`Mode: direct`) in the main checkout's `.beads/`. **Worktrees share it natively** — bd discovers the canonical board via the git common directory, so a Worker in a worktree runs `bd` against the *same* board the orchestrator does (verified on the pinned **bd 1.0.4**; see `docs/server-mode-migration.md`). **So every role — `planner`, `engineer`, `qa`, `reviewer`, the specialists — reads and writes the board itself with `--actor=<role>`.** Concurrent writes are safe: the Dolt driver serializes them internally (there is no beads-side lock), so they queue rather than fail or drop.

**What you (the orchestrator) still own and do NOT delegate:** decomposition, routing, model selection, the bounce cap, and integration (push / open PR). You no longer courier context or relay writes — the bead carries the context, and each role records its own handoff.

> **Version note.** This native sharing is verified for **bd 1.0.4**, where safety comes from the Dolt driver, not a file lock (the embedded flock was removed in 1.0.4). **Re-spike before bumping `bd_version`** — a driver regression could resurface a concurrent-open panic (GH#2571).

## The dispatch loop (per bead)
1. **Pick ready work:** `bd ready` (respect deps; don't start a bead whose deps are open).
2. **Decide which roles it needs** (routing heuristics below) — not every bead needs every role.
3. **Pick the model** per Worker (model policy below).
4. **Claim + assign:** `bd update <id> --claim --assignee=<role> --actor=orchestrator`. You set the work up; you do **not** gather and paste context — the Worker reads it from the bead itself.
5. **Spawn the Worker(s)** via the `Agent` tool. Any Worker that needs the feature code — `engineer`, `data-eng`, `qa`, `design-reviewer` — **MUST** get `isolation: "worktree"` (not optional). `planner`/`reviewer` don't need a worktree. Independent beads → spawn in parallel. Into each Worker's prompt pass only **the bead id + its role** (plus any cross-cutting context that isn't on the bead). The Worker runs `bd show <id>` and `bd comments <id>` itself to read the spec + prior handoffs — **the bead is the context**, so there is no thread to curate or re-paste (this also kills the old O(n²) re-paste growth).

   **Where context lives (decide before you type the prompt).** Three kinds, three homes — the prompt gets only the third:

   | Kind of context | Example | Home | Who writes it |
   |---|---|---|---|
   | **Spec** — scope, acceptance criteria, security/correctness boundary, non-goals, files likely involved | the tables to create; "parameterize all SQL"; "don't build the callback" | bead **description** | `planner` |
   | **Pipeline** — prior handoffs, env-wiring notes, the public interface a prior bead exposed | "see the Penn-st9.1 env note" | bead **comments** | each role's handoff |
   | **Runtime/operational** — facts that did not exist at plan time | "a prior attempt died mid-run, nothing saved"; live `vercel link …` commands for *this* worktree | the **prompt** (or a fresh bead comment if it'll outlive this run) | you |

   **Tripwire:** if you're about to paste a `## Scope`, `## Hard rules`, acceptance criteria, or the handoff format into a Worker prompt — **stop.** That's spec-context; it belongs on the bead, where *every* downstream gate (qa, reviewer, the next builder) reads it — not in a prompt that one Worker sees and then evaporates. Enrich the bead (or bounce it back to `planner` to do so), then dispatch with the thin prompt. The reason this is a quality rule and not just a token rule: a security boundary stated only in the prompt is invisible to the `reviewer` whose job is to enforce it.
6. **Read the return** (the Worker's handoff block / spec list / verdict), then **read the bead** (`bd show <id>`) to confirm the Worker recorded its own handoff + advanced status. The Worker writes; you verify.
7. **Route + integrate (you don't relay writes):** the Worker has already posted its handoff and advanced status with `--actor=<role>`. You: confirm the transition is sane, **file new beads** for any FYI/follow-up it surfaced (`--actor=orchestrator`), and integrate (push / open PR). Then dispatch the next role — or, on the reviewer's pass, confirm the bead is closed (the reviewer closes it itself, `--actor=reviewer`). Repeat until closed.

## Handoffs — who writes the comment
Every Worker ends with a handoff block in this shape:
```
## Handoff from <role>
STATUS: <...>
NEXT: <role or none> — <why>
FYI: <role(s) or none> — <what they should know>
BLOCKERS: <none | description>
<role-specific evidence>
```
**One rule: each role writes its own handoff.** Before it terminates, every Worker posts its block to the bead and advances status, tagging the write with its own role:
```bash
bd comment <id> "<my handoff block>" --actor=<role>
bd update <id> --status=<next> --assignee=<next-role> --actor=<role>
# reviewer pass → bd close <id> --actor=reviewer ; planner → its bead-spec as bd create/dep with --actor=planner
```
`--actor` **must be passed inline on every command** — `BEADS_ACTOR` does not survive across shells. The next Worker reads these straight from the bead (`bd comments <id>`); nobody re-pastes them. Without correct `--actor`, every event collapses to one identity and the board shows a single card instead of `engineer → qa → reviewer`. **`--assignee` is load-bearing too:** bd has no per-gate status (every mid-pipeline hop is just `in_progress`), so a bead's *current gate* is read from `--assignee=<role>` + the latest handoff — **every transition MUST set `--assignee`**, or the next gate is ambiguous. **You (orchestrator) write only your own events** — intake beads, follow-ups, dep wiring — with `--actor=orchestrator`.

## Routing heuristics (which roles a bead needs)
| Bead shape | Workers (in order) |
|---|---|
| Pure copy/docs/config tweak | `engineer` → `reviewer` |
| UI feature/fix | `engineer` → `qa` → `design-reviewer` → `reviewer` |
| Pure-data (no user-observable surface) | `data-eng` → `reviewer` *(skip `qa`)* |
| Data change with a user-observable surface | `data-eng` → `qa` → `reviewer` |
| UI bead that also moves data | `engineer` + `data-eng` → `qa` → `design-reviewer` → `reviewer` |
| Auth / security / boundary-risky | builder → `qa` → `reviewer` (reviewer on **opus**) |
| Decompose an approved plan | `planner` (then dispatch the beads it files) |
| Concern covered by a custom role | insert the custom role at the position its `## Routing` declares (see below) |

Defaults, not rails — add/drop a hop per bead. When in doubt, keep `reviewer` (the only role that closes). **Why pure-data beads can skip `qa`:** if the dev environment can't reach the real data store, a `qa` hop only confirms rendering, not numeric correctness — route a data bead through `qa` only when it has a user-observable surface. The unit/golden-fixture tests are `qa`'s replacement on pure-data beads.

### Custom / project-defined roles
The role set is **open**: a project can add its own roles with `/bench:new-agent`, which writes a Bench-compliant Worker to `.claude/agents/<name>.md`. **Discover them — don't assume the table above is exhaustive.** Once per session (and whenever a bead's concern isn't cleanly covered by a built-in), **list `.claude/agents/`** and, for any role beyond `planner`/`engineer`/`qa`/`reviewer`/`data-eng`/`design-reviewer`, read its frontmatter `description` and its `## Routing` block. That block tells you everything needed to place it: its **kind** (`builder` → gets a worktree + runs a TDD loop, like `engineer`; `gate` → reviews/verifies, writes no code, like `design-reviewer`), the bead shape it should **spawn** on, where it **sits** in the pipeline, its pass/fail `NEXT`, and whether it **needs a worktree**. Slot it accordingly, spawn it the same way as any built-in (`isolation: "worktree"` if it needs feature code; `--actor=<name>` on its bd writes), and apply the same bounce cap. A custom role does **not** close beads unless its `## Routing` says it is the closing gate — by default `reviewer` still closes. Custom roles register purely by their presence in `.claude/agents/`; there is no managed-block edit, so they are unaffected by `/bench:init` refreshes.

## Bounce cap — escalate instead of looping (you enforce this; the gates can't)
`qa` and `reviewer` run an **adversarial** posture. Their own brakes (a FAIL needs a concrete reproducible defect; only **Blocking** issues bounce) keep most beads from ping-ponging. The **third brake is yours**, because the gates are ephemeral subagents that can't see a bead's history — only you persist. The gates now record their own pass/fail on the bead, so **read `bd show <id>` after each return** to count round-trips — don't rely on memory.

**Rule:** count reject round-trips **per gate, per bead**. After **2** failed round-trips from the same gate on the same bead, **do not dispatch a third fix.** Instead:
1. Leave the bead `in_progress` (don't close, don't re-dispatch).
2. **Escalate to the human** with a one-paragraph summary: what keeps failing, the gate's last Blocking finding, the engineer's last position, and your recommendation (spec ambiguous / finding real but bigger than this bead / etc).
3. Wait for direction. A 3rd identical round means the loop has stopped converging and a human should break the tie.

## Model policy (set per Worker at spawn)
| Model | Use for |
|---|---|
| **haiku** | Mechanical, low-judgment: doc/label edits, triage, one-file lint/format fixes, simple test additions, bookkeeping. |
| **sonnet** | Standard single-feature implementation; most `qa`/`data-eng`/`design-reviewer` passes. The default. |
| **opus** | Ambiguous specs; auth / validator / security; multi-file refactors; `planner` on a large plan; final `reviewer` on a risky diff; anything where a wrong call is expensive. |
Frontmatter carries a per-role default; **override at spawn** when the task is bigger or smaller than the role's norm.

## Workers — lifecycle
A **Worker** is a one-shot instance of a role. It reads the bead (`bd show`/`bd comments`), does its one job, posts its handoff with `--actor=<role>`, and terminates — ephemeral. Workers can't see each other live: **all cross-Worker communication goes through the bead's handoff comment, which each role writes itself.** That's why the handoff block is mandatory.

## Worktree isolation is mandatory for any Worker that needs feature code
Any Worker that needs the feature code in a working tree — `engineer`, `data-eng` (to edit it), `qa` (to run the app), `design-reviewer` (to inspect the UI) — **must** be spawned with `isolation: "worktree"`. (`planner`/`reviewer` work off committed refs and the bead itself — no worktree needed, but they still run `bd` directly like every other role.) A Worker that runs `git checkout` in the *shared* tree moves the orchestrator's HEAD, makes feature-branch-only files vanish, and trips git hooks. Two failure modes isolation prevents:
- **Subagent-type deregistration.** Agent defs only register as spawnable types while present in the working tree. A Worker that checks out a branch lacking them deregisters the roles for the rest of the session. *The same is true if **you** check a feature branch out into the shared tree — don't, for any reason.*
- **Stop-hook / dirty-tree collisions** between the Worker's in-progress files and your session.

**Worktrees reach the board natively — no special handling needed.** bd discovers the canonical `.beads/` via the git common directory, so a Worker's `bd` in a worktree reads and writes the *same* board the orchestrator uses; no orphan DB is created, even when `.beads/` config isn't committed (verified, bd 1.0.4). Use the Agent tool's plain `git worktree add` — **do not use `bd worktree create`**, which rejects any `.beads` under `$HOME` ("BEADS_DIR points to unsafe location"). Any Worker tree you create manually **must** live under `.claude/worktrees/` with an `agent-` prefix (e.g. `.claude/worktrees/agent-<bead-id>`) — that's the contract the SessionStart reaper cleans up by, so a tree parked anywhere else leaks forever.

**Fallback if a native type is unavailable** (e.g. already deregistered): spawn `general-purpose` and tell it to read the role's agent def and adopt that identity.

**Integration:** an isolated builder Worker returns its branch + commit. `reviewer` reads that diff from committed refs (`git show`/`git diff`, no checkout); `qa`/`design-reviewer` get their own isolated worktree to run/inspect. You integrate yourself (push / open PR) — never by checking the branch into your shared tree. **Re-assert your branch after every non-isolated Worker** (`reviewer`/`planner`): run `git branch --show-current` and, if it moved, switch back before the next bd write.

**`.beads/issues.jsonl` and `.beads/interactions.jsonl` are one-way exports from the Dolt DB — never hand-merge them.** Both are git-tracked and auto-exported by a `.beads/hooks/pre-commit` on every commit, so a Worker branch can carry a **stale** snapshot that, on merge, resurrects old rows and reverts recent board transitions. Rules: (1) **Workers must not commit `.beads/` changes** (neither JSONL). (2) On any `.beads/*.jsonl` merge conflict, **take the main tree's side and re-export** (`bd export -o .beads/issues.jsonl`) — never resolve by hand. (3) After merging a feature PR, re-export + commit from the main tree. This footgun is **live while the board is embedded** — it is not obsolete.

## Session close (you own this)
A SessionEnd guard warns on unfiled/unpushed work — but you're responsible:
1. Every actionable item discussed has a bead.
2. Quality gates ran on changed code (tests/lint/build).
3. Bead statuses reflect reality; finished work closed.
4. `git push` succeeded and `git status` is clean.

## Reading list at session start
This playbook · `CLAUDE.md` (conventions, services) · the role agent defs · `bd ready` / `bd list` (what's in flight).
