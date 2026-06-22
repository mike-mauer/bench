---
name: bench-orchestrator
description: The Bench orchestration playbook — how the main session routes work through the planner→engineer→qa→reviewer agent pipeline using beads. Use when acting as the orchestrator: decomposing work into beads, spawning role Workers, relaying handoffs, enforcing the bounce cap, and isolating code Workers in worktrees. Read this before dispatching any multi-step engineering work through the agents.
---

# Orchestrator Playbook (Bench harness)

**The orchestrator is the main Claude session — not a registered agent.** Only the top session can spawn subagents, choose their model, isolate them in worktrees, and run them in parallel; only here are routing decisions visible to the human. If you're reading this as your identity, **you are the orchestrator.** You track work in beads and delegate it to ephemeral **Workers** (one-task subagents), then stitch their results together. You do **not** implement, verify, or review inline — your job is tracking + routing + model selection + integration. (Trivial bead bookkeeping is fine to do yourself.)

## Prime directive: track everything in beads first
Before acting on **any** actionable item — a feature, a bug noticed in passing, a decision reached in discussion, a review follow-up — **file a bead first**, then dispatch. No work happens off the books.
```bash
bd create --type <feature|bug|task|chore> --priority <p0..p3> --label <lane> \
  --title "<imperative, specific>" --description "<context + acceptance criteria>" --actor=orchestrator
```
Items from an approved plan route through a `planner` Worker (which *designs* the bead specs; **you** file them with `--actor=planner`); a single bug/discussion item you file directly and dispatch.

## Intake → the pipeline
```
plan/spec (brainstorm → design → plan, produced upstream)
  │  approved plan
  ▼
planner Worker  →  designs dependency-ordered bead specs (red-test criteria, lane labels); YOU file them with --actor=planner
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

## You are the ONLY bd process (the load-bearing safety rule)
The board is an **embedded** engine (in-process, single-writer; `bd dolt status` → `embedded`). **Every other role is a subagent, and subagents must run ZERO `bd` commands — all of them, `planner` and `reviewer` included.** A subagent's `bd` writes don't reliably reach the board: in server mode a spawned subagent can fire a **destructive auto-init** that re-stamps project identity and re-imports stale data; in embedded mode a subagent writes to a per-invocation engine and the write is simply lost. **So only you — the top-level session — ever run `bd`.** Every role returns its output as text; you perform all reads and writes with `--actor=<role>`, including `planner`'s `bd create`s and `reviewer`'s `bd close`. Being a spawned subagent is the hazard — worktree-vs-main-tree is irrelevant.

## The dispatch loop (per bead)
1. **Pick ready work:** `bd ready` (respect deps; don't start a bead whose deps are open).
2. **Decide which roles it needs** (routing heuristics below) — not every bead needs every role.
3. **Pick the model** per Worker (model policy below).
4. **Claim + gather context (you — the only bd process):** `bd update <id> --claim --actor=<role>`, then capture `bd show <id>` + the **prior handoff block** (`bd comments view <id>`). You hold the full thread; you pass forward the curated slice.
5. **Spawn the Worker(s)** via the `Agent` tool. Any Worker that needs the feature code — `engineer`, `data-eng`, `qa`, `design-reviewer` — **MUST** get `isolation: "worktree"` (not optional). `planner`/`reviewer` don't need a worktree but still **run zero bd**. Independent beads → spawn in parallel. Into each Worker's prompt, paste **curated context, not the whole thread**: the bead text + **the prior handoff block verbatim** (the most recent role's returned block), plus its role and the bead id. Re-pasting the entire growing comment thread on every hop is O(n²) token growth — the prior handoff already carries forward what the next role needs. **Escape hatch:** if a Worker reports it's blocked, paste the full thread on the next spawn.
6. **Read the return** (the Worker's handoff block / spec list / verdict).
7. **Post the handoff + advance (you run all bd):** `bd comment <id> "<the role's returned block>" --actor=<role>`, then `bd update <id> --status=<next> --assignee=<next-role> --actor=<role>` — or, for a `reviewer` pass, `bd close <id> --actor=reviewer`; for `planner`, run its `bd create`/`bd dep` spec with `--actor=planner`. **File new beads** for any FYI/follow-up surfaced. Repeat until you close the bead on the reviewer's pass.

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
**One rule, no split: NO role writes its own bead. Every role relays; you write.** Each returns its handoff block; **you post it verbatim and record the transition**, tagging both with the role that did the work:
```bash
bd comment <id> "<the role's handoff text>" --actor=<role>
bd update <id> --status=<next> --assignee=<next-role> --actor=<role>
# reviewer pass → bd close <id> --actor=reviewer ; planner → its bead-spec as bd create/dep with --actor=planner
```
`--actor` **must be passed inline on every command** — `BEADS_ACTOR` does not survive across shells. When you spawn the next Worker, **quote the `NEXT`/`FYI` lines meant for it.** Without correct `--actor`, every event collapses to one identity and the board shows a single card instead of `engineer → qa → reviewer`.

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

Defaults, not rails — add/drop a hop per bead. When in doubt, keep `reviewer` (the only role that closes). **Why pure-data beads can skip `qa`:** if the dev environment can't reach the real data store, a `qa` hop only confirms rendering, not numeric correctness — route a data bead through `qa` only when it has a user-observable surface. The unit/golden-fixture tests are `qa`'s replacement on pure-data beads.

## Bounce cap — escalate instead of looping (you enforce this; the gates can't)
`qa` and `reviewer` run an **adversarial** posture. Their own brakes (a FAIL needs a concrete reproducible defect; only **Blocking** issues bounce) keep most beads from ping-ponging. The **third brake is yours**, because the gates are ephemeral subagents that can't see a bead's history — only you persist.

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
A **Worker** is a one-shot instance of a role. It claims the bead (via the context you pasted), does its one job, returns its handoff, and terminates — ephemeral. Workers can't see each other live: **all cross-Worker communication goes through the bead's handoff comment, relayed by you.** That's why the handoff block is mandatory.

## Worktree isolation is mandatory for any Worker that needs feature code
Any Worker that needs the feature code in a working tree — `engineer`, `data-eng` (to edit it), `qa` (to run the app), `design-reviewer` (to inspect the UI) — **must** be spawned with `isolation: "worktree"`. (`planner`/`reviewer` work off committed refs / the context you paste — but still run zero bd.) A Worker that runs `git checkout` in the *shared* tree moves the orchestrator's HEAD, makes feature-branch-only files vanish, and trips git hooks. Two failure modes isolation prevents:
- **Subagent-type deregistration.** Agent defs only register as spawnable types while present in the working tree. A Worker that checks out a branch lacking them deregisters the roles for the rest of the session. *The same is true if **you** check a feature branch out into the shared tree — don't, for any reason.*
- **Stop-hook / dirty-tree collisions** between the Worker's in-progress files and your session.

**Isolation alone does NOT prevent board corruption — the zero-bd-subagent rule does.** Worktrees share the main checkout's `.beads/` but lack the gitignored local markers, so a subagent's `bd` can decide the project is uninitialized and fire `bd init`. The guarantee is that **no subagent runs bd at all.**

**Fallback if a native type is unavailable** (e.g. already deregistered): spawn `general-purpose` and tell it to read the role's agent def and adopt that identity.

**Integration:** an isolated builder Worker returns its branch + commit. `reviewer` reads that diff from committed refs (`git show`/`git diff`, no checkout); `qa`/`design-reviewer` get their own isolated worktree to run/inspect. You integrate yourself (push / open PR) — never by checking the branch into your shared tree. **Re-assert your branch after every non-isolated Worker** (`reviewer`/`planner`): run `git branch --show-current` and, if it moved, switch back before the next bd write.

**`.beads/issues.jsonl` is a one-way export from the Dolt DB — never hand-merge it.** Worker branches carry a **stale** export (they run zero bd); on merge, git can resurrect it and revert recent board transitions. Rules: (1) Workers must not commit `.beads/` changes. (2) On any `issues.jsonl` merge conflict, **take your side and re-export** (`bd export -o .beads/issues.jsonl` from the main tree) — never resolve by hand. (3) After merging a feature PR, re-export + commit `issues.jsonl`.

## Session close (you own this)
A SessionEnd guard warns on unfiled/unpushed work — but you're responsible:
1. Every actionable item discussed has a bead.
2. Quality gates ran on changed code (tests/lint/build).
3. Bead statuses reflect reality; finished work closed.
4. `git push` succeeded and `git status` is clean.

## Reading list at session start
This playbook · `CLAUDE.md` (conventions, services) · the role agent defs · `bd ready` / `bd list` (what's in flight).
