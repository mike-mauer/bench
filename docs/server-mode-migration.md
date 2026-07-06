# Migration: embedded mode → Dolt server mode (GitHub-backed, Topology B)

**Status:** design / proposal
**Branch:** `claude/agent-reporting-methodology-nel4q4`
**Decision inputs:** Topology B (ephemeral container boots its own local Dolt server; GitHub
`refs/dolt/*` as the durable remote; no DoltHub, no web-exposed server). Goals: agent-native
tracking, observability of work/learnings, a fresh-context impl↔test loop, and smooth
multi-agent concurrency without sync races.

---

## 1. Why this change

Bench today runs beads in **embedded mode** (in-process Dolt, single-writer, file-locked).
That single choice forces the harness's most restrictive rule — **subagents run zero `bd`** —
because a spawned subagent either writes to a throwaway per-invocation engine (write lost) or,
in a worktree that lacks the gitignored `.beads/embeddeddolt`, fires a destructive auto-init.
The orchestrator is therefore the *sole* `bd` process and the *courier* of all context.

That defeats the point of beads' concurrency model. Beads moved SQLite→Dolt specifically to
kill the single-writer bottleneck; the intended multi-agent path is **server mode**, where all
agents connect to one `dolt sql-server` and Dolt's cell-level merge + hash IDs make concurrent
writes safe. Gas Town (the reference deployment) runs ~160 agents/host this way; without Dolt it
"struggled at more than four."

**Switching embedded → server is the whole migration.** The GitHub remote does **not** change —
Bench already pushes Dolt history to `git+origin` via `refs/dolt/*` (`beads-cloud-push.sh`) and
rehydrates from it (`beads-bootstrap.sh`). What changes is the local *engine* and, downstream of
that, the entire subagent access model.

---

## 2. Before → after

| Dimension | Today (embedded) | After (server) |
|---|---|---|
| Local engine | In-process Dolt, single-writer, file lock | `dolt sql-server` (localhost) inside the container, multi-writer |
| Data dir | `.beads/embeddeddolt/` (gitignored) | `.beads/dolt/` (gitignored) |
| Sync mode | implicit / export-based | `sync-mode: dolt-native` in `.beads/config.yaml` |
| Who runs `bd` | **Orchestrator only** | **Every role** — orchestrator + all subagents |
| Context delivery | Orchestrator curates + pastes into each prompt | **Bead delivers it** — agent runs `bd show` / `bd comments view` itself |
| Handoff comments | Orchestrator posts verbatim with `--actor` | Each agent posts its own with `--actor=<role>` |
| Worktrees & `bd` | bd-blind (board-corruption hazard) | Redirected at the shared local server; run `bd` freely |
| Durable remote | `git+origin` `refs/dolt/*` | **unchanged** — `git+origin` `refs/dolt/*` |
| Observability | CLI only | CLI **+ live server** BeadBox can connect to |

The resolved win: the thing the user originally asked for three iterations ago — "context
delivered by the bead, not the orchestrator" — falls out automatically, and the O(n²)
prompt-curation problem disappears.

---

## 3. Risks / open questions to resolve BEFORE coding

1. **Does server mode need a separate `dolt` binary? — RESOLVED: yes, and `bd` won't auto-start
   it.** The prebuilt release / `install.sh` / `brew install beads` is the *embedded-capable*
   build (`CGO_ENABLED=1 -tags=gms_pure_go`); `bd` bundles the embedded engine, so embedded "just
   works" with no extra binary. **Server mode requires the standalone `dolt` CLI installed
   separately**, plus `bd init --server` pointed at *a running* `dolt sql-server` that the harness
   must launch and manage itself (the 1.0.x line does **not** auto-start a server — Gas Town only
   gets auto-start via its `gt` daemon). Consequences for the plan:
   - `install-bd.sh` must also install a (pinned) standalone `dolt` binary.
   - `beads-server-up.sh` must *explicitly launch* `dolt sql-server`, health-check it, and run
     `bd init --server` / set the project to server mode — not just flip a config flag.
   - The "zero ops, no server, no ports" property is genuinely lost; this is a real cost.

   **Strategic context (verified during Q1):** beads' history is SQLite → server-Dolt (v0.50–0.58)
   → **reverted to embedded-as-default (v1.0.x)** because mandatory server mode was "a regression
   for standalone users" (upstream issue #2050). So Bench's embedded choice is the *current
   upstream default*, and this migration deliberately re-adds the ops burden upstream removed — a
   justified trade **only if** concurrent autonomous multi-writer board access is a hard
   requirement. If the real need is "a few agents, occasional parallelism," embedded + the current
   model (or worktree+git-sync) is lighter and closer to upstream's intent.
2. **Server boot vs. async bd install.** `install-bd.sh` installs `bd` *detached* so SessionStart
   never blocks; `bd` may not exist yet when the hook returns. Server start must be sequenced
   **after** bd lands — fold it into the same post-install step that already calls
   `beads-bootstrap.sh` (line 91), not into a separate hook that could fire too early.
3. **Cross-session push race.** Topology B sessions each push to the shared `git+origin`
   `refs/dolt/*` at SessionEnd. Two *concurrent* sessions pushing is the "multiple clones syncing
   simultaneously" race. Single-user sessions are usually sequential; `cloud-push` already does
   `dolt pull` → `dolt push`. Document the limitation; true concurrent cross-machine boards are
   Topology C (web server), explicitly out of scope here.
4. **`issues.jsonl` role.** Keep it as a human-readable export refreshed on push, never
   source-of-truth. In dolt-native it's out of the hot path; do **not** adopt belt-and-suspenders
   (writes Dolt *and* flushes JSONL every mutation → I/O + sync conflicts).
5. **Port management.** Per-project server on default 3307 is simplest for one container. Shared
   server (`~/.beads/shared-server/`) is a multi-project optimization — defer.

---

## 4. File-by-file change inventory

### A. Hooks & scripts (lifecycle)

- **`hooks/hooks.json`** — SessionStart: after `install-bd.sh`, ensure a Dolt server is up.
  SessionEnd: before/around `beads-cloud-push.sh`, flush + push from the server, then stop it.
- **`scripts/install-bd.sh`** — **must add a pinned standalone `dolt` install** alongside `bd`
  (Q1 resolved: server mode needs it). Linux: `curl -L .../dolt/releases/.../install.sh | bash`;
  macOS: `brew install dolt`. Keep it detached/best-effort like the bd install. After both land
  (line ~91), call the new `beads-server-up.sh`.
- **NEW `scripts/beads-server-up.sh`** — idempotent: if no server on the configured port,
  **explicitly launch `dolt sql-server`** (bd does not auto-start one), wait for readiness, then
  ensure the project is server-mode (`bd init --server` if uninitialized; `.beads/config.yaml`
  `sync-mode: dolt-native`, `.beads/metadata.json` pointing at the port). Best-effort exit 0, but
  agents must fail loud (not auto-init) if the server isn't up.
- **`scripts/beads-bootstrap.sh`** — still rehydrates from `git+origin` `refs/dolt/*`, but loads
  into the **server's** `.beads/dolt/` rather than `.beads/embeddeddolt/`. Update the comment
  block (it currently names `.beads/embeddeddolt` as the gitignored DB).
- **`scripts/beads-cloud-push.sh`** — push from the running server's data dir; ensure the server
  has flushed/committed first. Logic (`dolt pull` → `dolt push` to `git+${ORIGIN}`) is otherwise
  intact. Consider promoting from web-only to also stopping the server cleanly.
- **NEW `scripts/beads-server-down.sh`** (or fold into cloud-push) — flush, `bd dolt push`, stop
  the server. Must run before container teardown.
- **`scripts/worktree-reap.sh`** — unchanged in intent, but worktrees now carry a server
  redirect; confirm reaping doesn't orphan a redirect/metadata.

### B. The orchestrator playbook — the heart of the rewrite

- **`skills/bench-orchestrator/SKILL.md`**
  - **Delete / invert** "You are the ONLY bd process" (§ lines ~45–46). Replace with: a shared
    local server; every role runs `bd` directly with `--actor=<role>`.
  - **Dispatch loop** (§ lines ~48–55): the orchestrator claims + routes, but no longer pastes
    curated context — it passes the **bead id**, and the agent reads `bd show` / `bd comments
    view` itself. Drop the O(n²) curation rationale and the "escape hatch: paste full thread."
  - **Handoffs — who writes the comment** (§ lines ~57–73): invert the "NO role writes its own
    bead" rule. Each role now writes its own handoff comment + status transition with
    `--actor=<role>`. The orchestrator still owns routing decisions and the bounce cap.
  - **Worktree isolation** (§ lines ~107–118): **keep** the rule, **change the reason** — worktrees
    still isolate *code* (don't move shared HEAD, don't trip hooks), but the board-corruption
    rationale and the `issues.jsonl` resurrection warning are obsolete in dolt-native (agents
    don't commit `.beads/` and the server is the single source of truth).
  - **Bounce cap, routing, model policy** — unchanged.

### C. Agent role definitions (the "zero bd" prose)

Each carries a paragraph asserting "you are a subagent and must run ZERO bd / embedded
single-writer / auto-init hazard." Replace with: "connect to the session's beads server; read
your context via `bd show` + `bd comments view`; on finish, post your handoff and advance status
yourself with `--actor=<role>`."

- **`agents/engineer.md`** (lines ~13, ~18–22, ~71, ~101) — heaviest; also update the "return as
  text, orchestrator records" framing throughout.
- **`agents/reviewer.md`** (lines ~13, ~25–29, ~55) — reviewer now runs `bd close --actor=reviewer`
  itself.
- **`agents/qa.md`**, **`agents/planner.md`** — same zero-bd prose to invert. `planner` now files
  its own `bd create`/`bd dep` specs with `--actor=planner`.
- **`agents-optional/data-eng.md`**, **`agents-optional/design-reviewer.md`** — same.

### D. Project-facing template & commands

- **`templates/CLAUDE.bench.md`** (lines ~29–31) — the "Only the main session runs `bd`. Pipeline
  subagents run ZERO bd… embedded single-writer board loses or corrupts subagent writes" bullet is
  now false. Replace with the server-mode access rule. **Note:** this is content-hashed and
  injected by `/bench:init`; changing it bumps the drift-check, so existing projects get a
  "re-run /bench:init" nudge — intended.
- **`commands/init.md`** (Step 2) — `bd init` must initialize a **server-mode** board
  (`sync-mode: dolt-native`, metadata.json), and ensure a server is started. Document the new
  `.beads/config.yaml` shape.
- **`commands/doctor.md`** — add server-health checks (is the server up? port reachable? mode ==
  dolt-native?) alongside the existing bd-version / hooks / drift checks.

### E. Maintenance skill

- **`skills/beads-health-check/SKILL.md`** — already distinguishes embedded vs server
  (`bd dolt show` → embedded/server) and gates `bd doctor` on mode. Flip the default-expected mode
  to **server**, and make the embedded branch the fallback/legacy note.

---

## 5. New safety model (what replaces "zero bd")

The old invariant ("only the orchestrator touches `bd`") is replaced by three server-mode
invariants:

1. **One server per session, started before any agent runs.** Boot in `beads-server-up.sh`,
   sequenced after `bd` lands. Agents that race ahead of the server should fail loud, not
   auto-init.
2. **dolt-native only; no bd daemons; no belt-and-suspenders.** These are the documented
   race sources. The server is the single writer-of-record; agents are clients.
3. **Worktrees redirect to the server, never own a DB.** Each worktree gets a redirect /
   `metadata.json` pointing at the one server (Gas Town's `.beads/redirect` pattern), so a
   subagent's `bd` reaches the shared board instead of auto-initing an orphan. Agents still must
   not commit `.beads/` changes.

---

## 6. Phased rollout

1. **Phase 0 — settle Q1 (dolt binary) and Q2 (boot sequencing).** Spike `beads-server-up.sh` +
   `install-bd.sh` change in isolation; prove a server comes up in an ephemeral container and
   `bd ready` works against it.
2. **Phase 1 — lifecycle.** Wire server up/down into hooks; adapt bootstrap + cloud-push to the
   server data dir. Verify rehydrate-from-GitHub and push-to-GitHub round-trip.
3. **Phase 2 — access model.** Rewrite the orchestrator skill + all agent defs to let agents run
   `bd` directly with `--actor`. This is the behavioral switch; do it as one reviewed change so
   the board never sees a half-migrated mix.
4. **Phase 3 — project surface.** Update `CLAUDE.bench.md` (bumps drift hash), `init.md`,
   `doctor.md`, health-check. Existing projects re-run `/bench:init`.
5. **Phase 4 — docs + a migration note** for boards already living in embedded mode (one-time
   `bd dolt` mode switch + verify `bd list` superset).

---

## 7. Side-by-side: which concurrency model to actually adopt

Three real options reach the four goals (agent-native tracking · observability · fresh-context
impl↔test loop · smooth concurrency). The fresh-context loop (goal 3) is **orthogonal** — all
three support it — so it's omitted from the matrix; the decision turns on concurrency and ops.

| Dimension | **A. Embedded + courier** (current) | **B. Worktree + git-sync** | **C. Server mode (dolt-native)** |
|---|---|---|---|
| Live shared board during a run? | One board, but **only the orchestrator** sees/writes it | **No** — each agent has its own embedded DB; reconciled at merge | **Yes** — one live server all agents read/write in real time |
| Who runs `bd` | Orchestrator only | **Every agent** (in its own worktree DB) | **Every agent** (as a client of the server) |
| Context delivery | Orchestrator curates + pastes (courier) | Bead — agent reads its own DB copy | Bead — agent reads the live board |
| Consistency model | Serialized through one process | **Eventual** — agents see stale peers until a sync/merge | **Strong** — single source of truth, immediate |
| Cross-agent claim/coordinate | N/A (orchestrator assigns) | **Races** if agents self-claim from a shared queue; **safe if the orchestrator partitions disjoint beads up front** | Safe — atomic `--claim` against the live board |
| Conflict handling | None needed | Dolt cell-level merge + hash IDs on merge | Dolt server, in-flight |
| Ops burden | **Zero** (no server, no extra binary) | **Zero daemon** — but per-worktree DB bootstrap/push choreography | **Daemon** — pinned `dolt` binary + launch/health-check/`bd init --server` lifecycle |
| Upstream alignment | **Current default** (v1.0.x embedded) | Embedded, supported (Yegge's "agent village") | Supported, but the path upstream walked back for standalone (#2050) |
| Practical scale ceiling | 1 writer | A handful → moderate; "git sync doesn't scale to high-frequency concurrent edits" | **Dozens–hundreds** (Gas Town: ~160/host) |
| Goal 1 — agent-native tracking | ✔ (via orchestrator) | ✔ (agents write directly) | ✔ (agents write directly) |
| Goal 2 — observability | CLI, orchestrator-mediated | CLI + git history per bead | CLI + git history + **live server for BeadBox** |
| Goal 4 — smooth concurrency | ✗ serialized, not concurrent | ✔ for disjoint work; ✗ for shared-queue self-claim | ✔ unconditionally |
| Migration effort from today | none | **medium** — drop courier rule, add per-worktree bd bootstrap/push, keep embedded | **large** — §4 inventory: daemon lifecycle + access-model rewrite |
| Main risk | Courier bottleneck; not really concurrent | Sync races / stale views; reconcile complexity | Daemon lifecycle in ephemeral containers; re-added ops |

### The deciding question: *who decides what each agent works on?*

- **Orchestrator partitions disjoint beads up front** (Bench's existing Phase-0→fan-out→reconcile
  parallel-lane protocol): no two agents touch the same bead, so there are **no real write
  conflicts** — **B (worktree + git-sync)** gets you direct agent `bd` writes, observability, and
  concurrency **with zero daemon**, staying on the upstream-default embedded engine. This is the
  lighter path and it fits how Bench already decomposes work.
- **Agents autonomously self-claim from a shared ready-queue**, or you want real-time cross-agent
  visibility, or you're targeting **dozens** of concurrent agents: the eventual-consistency window
  in B becomes a claim-race, and only **C (server mode)** is safe. This is the Gas Town regime.

### Recommendation by scale

- **2–5 occasional parallel lanes, orchestrator-partitioned** → **Option B.** Hits all four goals,
  no daemon, smallest migration, upstream-aligned. (Resolves the original "agents write their own
  handoffs" ask without re-adding ops.)
- **Dozens of agents, or autonomous self-claiming, or a shared live board across sessions** →
  **Option C** (this doc's plan). The ops cost is the price of that regime.
- **Concurrency is rare / simplicity paramount** → stay on **A**.

## 8. Option B implementation plan (designed C-forward) — SUPERSEDED by §11

> **⚠️ Superseded.** This section designed a hydrate/reconcile mechanic for worktree boards. The
> §9 spike proved bd 1.0.4 shares the canonical board across worktrees *natively* (git-common-dir
> discovery), so the hydrate/reconcile machinery here is unnecessary. Kept for history; the live
> plan is **§11 (Option B′)**.

We adopt **Option B (worktree + git-sync, no daemon)** now, structured so a later move to
**Option C (server mode)** is a transport swap — not an agent or orchestrator rewrite. The
governing principle:

> **Agents are board-mode-agnostic.** Every agent's contract is the same in B and C: "the project
> board is reachable; read your context from the bead and write your handoff with
> `--actor=<role>`." *How* the board is reached (per-worktree synced DB in B, live server in C)
> lives entirely in the lifecycle scripts + one config knob — never in an agent prompt.

### 8.1 The B-read vs B-write fork (decide first)

The hard part of B is that a worktree has no bd DB (`.beads/embeddeddolt` is gitignored, so it
isn't copied into a worktree). Two flavors differ only on the **write** path:

- **B-read (recommended).** The orchestrator hydrates each worktree with a board snapshot so the
  agent **reads context from the bead itself** (`bd show` / `bd comments view`) — satisfying the
  original "context delivered by the bead, not the orchestrator" goal. The agent still **returns
  its handoff as text and the orchestrator writes it** to the canonical board with `--actor=<role>`
  (which the user explicitly accepted: *"each sub agent writing **(or telling the orchestrator to
  write)** a report"*). **No DB-merge mechanic needed** — writes never originate in the worktree.
- **B-write (heavier).** Worktrees get *writable* DBs; agents run `bd comment`/`bd update`
  themselves; the orchestrator reconciles each returned worktree DB back into canonical via Dolt
  cell-level merge. Closer to C's write path, but adds an unproven local-DB merge step that is
  thrown away when C arrives anyway (the server makes it moot).

**Recommendation: B-read.** It delivers the read-path goal and concurrency with the *least* new
machinery, and its throwaway-on-C surface (a read-only hydrate + the existing relay) is smaller
than B-write's (hydrate + merge). The write path stays exactly as it is today until C flips both
reads and writes to the live server.

### 8.2 Architecture (B-read)

```
orchestrator (canonical embedded board, main tree)
  │  partitions disjoint beads (existing Phase-0 → fan-out protocol)
  │  for each lane: snapshot canonical board → hydrate the lane's worktree (read-only)
  ▼
worktree agent  ── reads context itself: bd show <id> / bd comments view <id> ──┐
  │  does its one job (TDD loop), returns handoff block as text                  │
  ▼                                                                              │
orchestrator  ── writes the returned handoff to canonical: bd comment/update --actor=<role> ──┘
```

The snapshot-hydrate-before and relay-after are the **seam**. In C both collapse: agents read
*and* write the live server, the hydrate is gone, the relay is gone.

### 8.3 The seam: `BENCH_BOARD_MODE`

One config knob (env or `.beads`-adjacent setting), read **only** by lifecycle scripts +
`doctor` — never by agents:

| `BENCH_BOARD_MODE` | hydrate worktree | agent reads | agent writes | reconcile |
|---|---|---|---|---|
| `worktree-sync` (B) | read-only snapshot | direct (`bd show`) | relayed by orchestrator | none |
| `server` (C) | none (points at server) | direct (live) | direct (live) | none |

### 8.4 File inventory — split by layer

**Mode-agnostic core (identical for B and C — the durable rewrite):**
- `skills/bench-orchestrator/SKILL.md` — replace "you are the ONLY bd process" with the seam
  model: agents **read** the bead directly; the orchestrator hydrates worktrees and (in B) relays
  writes. Keep routing / bounce-cap / decompose unchanged. Drop the O(n²) curated-context rule —
  context now comes from the bead.
- `agents/*.md`, `agents-optional/*.md` — the "run ZERO bd" prose becomes "read your context with
  `bd show <id>` / `bd comments view <id>`; return your handoff block." (No change to the
  return-as-text handoff itself in B-read — only the *read* path changes.)
- `templates/CLAUDE.bench.md` — rewrite the "Only the main session runs bd … subagents run ZERO
  bd" bullet to "agents read the board directly; the orchestrator hydrates worktrees and records
  transitions with `--actor`." (Bumps the drift hash → existing projects re-run `/bench:init`.)

**B-transport (thrown away / no-op'd when C lands):**
- NEW `scripts/beads-worktree-hydrate.sh` — given a worktree path, materialize a read-only board
  snapshot the agent can `bd show` against (exact mechanic = spike, §8.5).
- `skills/bench-orchestrator/SKILL.md` dispatch loop — add "snapshot → hydrate the worktree"
  before spawn; keep the relay after return.
- `scripts/worktree-reap.sh` — clean up hydrated snapshots on reap.

**C-transport (deferred; already inventoried in §4):**
- `install-bd.sh` (+`dolt`), `beads-server-up.sh`/`-down.sh`, `sync-mode: dolt-native` — all gated
  behind `BENCH_BOARD_MODE=server`. None of the mode-agnostic core changes when these arrive.

### 8.5 Spike (validate before the core rewrite) — needs a live `bd`

The whole plan rests on one unproven mechanic: **can a worktree cheaply get a readable board
snapshot?** Spike candidates, fastest-first:
1. `bd export` from canonical → a file the worktree reads via a fresh `bd init` + import, OR
2. a local Dolt clone of `refs/dolt/data` into the worktree's `.beads/`, OR
3. simply un-gitignoring/copying a read-only `.beads/embeddeddolt` snapshot into the worktree.

Acceptance: in a worktree, `bd show <id>` and `bd comments view <id>` return the canonical board's
content, **without** the worktree auto-initing an orphan or mutating canonical. Pick the cheapest
that passes. (Spike harness lives outside the repo; only the chosen mechanic lands in
`beads-worktree-hydrate.sh`.)

### 8.6 Sequencing

1. **Spike §8.5** — pick the hydrate mechanic. *Blocking for the B-transport scripts only.*
2. **Mode-agnostic core** — rewrite skill + agent defs + template to the read-from-bead contract.
   Safe to do in parallel with the spike; it's identical for B and C.
3. **B-transport** — `beads-worktree-hydrate.sh` + dispatch-loop hydrate step, behind
   `BENCH_BOARD_MODE=worktree-sync` (the default).
4. **doctor / health-check** — report mode + hydrate health.
5. **(Later) C** — §4 inventory behind `BENCH_BOARD_MODE=server`; no core changes.

## 9. Spike findings (bd 1.0.4) — COURSE CORRECTION

A live spike against **bd 1.0.4** (Bench's exact pinned version, embedded `Mode: direct`)
invalidates the premise this whole doc was built on. Evidence:

1. **Worktrees share the canonical board natively.** A plain `git worktree add` + `bd show <id>`
   in the worktree returned the **canonical** bead — no hydrate, no redirect, no orphan auto-init.
   bd's own help: *"Worktrees automatically share the same beads database as the main repository
   via git common directory discovery — no manual redirect configuration needed."*
2. **Worktree writes reach canonical, correctly attributed.** `bd comment`/`bd update
   --actor=engineer` from a worktree landed on the main-tree board, tagged `engineer`.
3. **Concurrent writes do not fail or lose data.** 16/16 — and, under an independent adversarial
   re-test, **up to 150-way** concurrent writes (same-bead, same-field, mixed
   create/update/comment/close) — all returned exit 0 with **zero lost or duplicated writes**;
   80 distinct `--actor` values preserved with no collapse. **Correction (mechanism):** this is
   *not* a single-writer file lock. bd 1.0.4 **removed** the embedded flock (CHANGELOG
   `[1.0.4]`, PR #3614: *"the process-lifetime exclusive flock on `.beads/embeddeddolt/` has been
   removed; concurrent `bd` processes now open the embedded engine independently"*). Concurrent
   safety is provided by the **Dolt driver's internal serialization**, not by beads. The flock had
   existed to prevent a concurrent nil-deref panic (GH#2571); that panic class is now **latent** —
   not reproducible in the spike, but the reason a future driver/version bump must be re-spiked.

**Implication:** the `zero-bd-subagent` rule — and therefore both the elaborate Option B
(hydrate/reconcile, §8) *and* Option C (server daemon, §4) — are **unnecessary to reach the four
goals at small-to-moderate scale.** bd 1.0.4 already lets worktree agents read and write one shared
embedded board safely. My §8 hydrate/reconcile design was solving a problem this bd version already
solved.

### 9.1 Revised recommendation — Option B′ (native shared embedded board)

- **Drop the zero-bd-subagent rule.** Worktree agents run `bd` directly: read context from the
  bead (`bd show <id>`), write their own handoff (`bd comment … --actor=<role>`) and status.
- **Stay embedded.** No daemon, no `dolt` binary, no hydrate, no reconcile, **no new scripts**.
- **Use the Agent tool's plain `git worktree add`** (the proven-safe path — git-common-dir
  discovery works on it, verified incl. nested `.claude/worktrees/<id>`). **Do NOT recommend
  `bd worktree create`:** it rejects any `.beads` under `$HOME` with *"BEADS_DIR points to unsafe
  location"* (verified — fails for `/root/...`, succeeds only under `/tmp`), and real projects live
  under home. Plain `bd create/show/comment` are unaffected by that guard.
- The migration becomes **almost entirely prose** — the §8.4 "mode-agnostic core" (orchestrator
  skill + agent defs + `CLAUDE.bench.md`) — and that prose is *identical* to what C would need, so
  **the C path stays open as a pure transport swap** (install dolt, start server, set
  `sync-mode: dolt-native`; agent contract unchanged). Exactly the C-forward seam, achieved for
  free.

### 9.2 Adversarial checks — RUN, both passed

- **Why did Bench claim the opposite?** Almost certainly a pre-1.0 bd hazard (older versions could
  orphan a worktree DB) that 1.0.4's git-common-dir discovery fixed — the rule outlived its cause.
- **(a) Uncommitted-`.beads` worktree — PASS.** Even with `.beads/` *not* git-committed, a worktree
  `bd show <id>` returned the canonical bead and created **no `embeddeddolt` orphan** in the
  worktree. git-common-dir discovery holds in exactly the condition the old rule feared.
- **(b) No hidden server — PASS.** `metadata.json` → `"dolt_mode": "embedded"`; no
  `dolt-server.*`/socket/pid files; no `dolt sql-server` process. The server-runtime entries in
  the default `.gitignore` are defensive only.
- **Latency ceiling is real (and the only reason C ever becomes necessary).** Driver
  serialization (not a lock) adds latency that grows with concurrent write frequency: ≈430ms/write
  at 16-way, **≈540ms/op at 150-way** (≈81s wall for 150 ops, adversarial re-test). Fine for a
  handful of agents doing periodic handoff writes (your stated scale); for *dozens* of
  high-frequency writers it compounds, and server mode (C) wins. Correctness is not the limit —
  latency is.

### 9.3 Revised sequencing

1. **Adversarial edge-case checks (§9.2).** Cheap; confirms it's safe to drop the rule.
2. **Mode-agnostic core rewrite** (skill + agent defs + template) to "agents run bd directly with
   `--actor`." This is now ~all of the work, and it's low-risk prose.
3. **Switch dispatch to `bd worktree create`/`remove`**; update `worktree-reap.sh`.
4. **doctor / health-check** wording.
5. **(Later, only if scale demands) Option C** — §4 inventory, unchanged by the above.

### 9.4 Independent adversarial review (subagent) — corrections folded in

A separate subagent re-attacked claims 1–4 (web research + hands-on, up to 150-way concurrency,
kill-mid-write, same-field lost-update races, close races, nested `.claude/worktrees/` paths,
uncommitted-`.beads`). **Data-integrity foundation held** — it could not lose or corrupt a write.
But it caught three wrong *premises*, now corrected above and in §11 (all independently re-verified
against the binary):

1. **Mechanism was wrong** — bd 1.0.4 removed the flock (PR #3614); safety is Dolt-driver
   serialization, GH#2571 latent. (§9 item 3, §11.6)
2. **`bd worktree create` is broken under `$HOME`** — use plain `git worktree add`. (§9.1, §11.3.A)
3. **`issues.jsonl`/`interactions.jsonl` resurrection warning is still live** — keep it, don't
   delete. (§11.3.A)
Plus: `bd doctor` unsupported in embedded (§11.3.D); C lifecycle has open reliability bugs (§11.4);
`.lock` always present idle (§11.3.D). *Conclusion: build B′; the three corrected premises were the
only flaws.*

## 11. Option B′ implementation plan (live plan, C-forward)

The plan of record. B′ = **let worktree subagents run `bd` directly against the one shared embedded
board** (proven safe on bd 1.0.4 in §9). It is overwhelmingly a **prose change** to three surfaces;
**no new scripts, no `dolt`, no daemon, no hydrate/reconcile.** Every change is written so a later
flip to Option C (server) touches *only* lifecycle scripts + one config knob — never an agent.

### 11.1 Governing principle (the C seam)

> **Agents are board-mode-agnostic.** Each agent's contract is identical in B′ and C: *"the project
> board is reachable from your worktree — read your context from the bead and write your handoff
> with `--actor=<role>`."* Mode-specific facts (embedded, file-lock, git-common-dir discovery vs.
> a `dolt sql-server`) live **only** in the orchestrator skill + lifecycle scripts + this doc.
> Agent defs must say **"the project board,"** never **"the embedded board"** — so C needs zero
> agent edits.

`BENCH_BOARD_MODE` (default `embedded`; later `server`) is read **only** by lifecycle scripts and
`doctor`. B′ ships with `embedded` and never reads the knob from an agent.

### 11.2 Scope — what changes vs. what explicitly does NOT

**Changes (3 prose surfaces):**
1. `skills/bench-orchestrator/SKILL.md` — the access model + dispatch loop + handoff ownership.
2. `agents/*.md` + `agents-optional/*.md` — the "zero bd" paragraph → "read/write the board directly."
3. `templates/CLAUDE.bench.md` — the "only the main session runs bd" bullet (bumps drift hash).

**Explicitly unchanged (important — keeps the diff small and the risk low):**
- `install-bd.sh` (no `dolt`), `beads-bootstrap.sh`, `beads-cloud-push.sh`, `beads-stop-guard.sh`
  — embedded + `git+origin` `refs/dolt/*` sync is untouched.
- `worktree-reap.sh` — still reaps orphaned git worktrees.
- `hooks.json` — no new hooks.
- No `beads-server-up.sh`/`-down.sh`, no `sync-mode` config (those are C-only, §4).

### 11.3 Detailed edits

**A. `skills/bench-orchestrator/SKILL.md`**
- **Delete** "You are the ONLY bd process" (§ lines ~45–46). Replace with **"The board is one
  shared embedded engine; the orchestrator and every worktree agent run `bd` directly against it
  (git-common-dir discovery — verified bd 1.0.4). Concurrent writes serialize on the file lock, they
  do not fail."**
- **Dispatch loop** (~48–55): the orchestrator still **claims/assigns** and **integrates** (push/PR),
  but:
  - drop "gather context / paste the curated slice" → spawn with **just the bead id + role**; the
    agent runs `bd show <id>` / `bd comments <id>` itself.
  - drop "Post the handoff + advance (you run all bd)" → the **agent** writes its own
    `bd comment … --actor=<role>` + `bd update`/`bd close`. The orchestrator verifies and routes.
  - delete the O(n²)-curation rationale and the "escape hatch: paste full thread" (moot — the bead
    is the context).
- **"Handoffs — who writes the comment"** (~57–73): invert to **"each role writes its own handoff
  comment + status transition with `--actor=<role>`."** Keep the handoff *block format* verbatim —
  it's still the inter-agent contract.
- **Worktree isolation** (~107–118): **keep the rule, narrow the reason** to code isolation (don't
  move shared HEAD, don't trip hooks). **Delete only the board-corruption / auto-init rationale**
  (obsolete — git-common-dir discovery, §9). Use plain `git worktree add` (NOT `bd worktree
  create`, which fails under `$HOME`).
- **KEEP and EXTEND the `issues.jsonl`-resurrection warning** — *do not delete it.* The board stays
  **embedded** (not dolt-native), and both `.beads/issues.jsonl` **and `.beads/interactions.jsonl`**
  are git-tracked and auto-exported by a `.beads/hooks/pre-commit` on every commit (verified). A
  worktree branch carries a *stale* snapshot and can revert board transitions on merge. The
  resurrection footgun is **live**; reword its rationale from "dolt-native makes it moot" to "still
  required while embedded," and cover both JSONLs.
- **Bounce cap, routing heuristics, model policy:** unchanged.
- **`.beads/` commit discipline:** keep "Workers don't commit `.beads/`; re-export from canonical
  after a feature merge" — now load-bearing (see above), and it must include `interactions.jsonl`.

**B. Agent defs** (`engineer`, `qa`, `reviewer`, `planner`, +optional `data-eng`, `design-reviewer`)
- Replace the "you are a subagent, run ZERO bd, embedded single-writer/auto-init hazard" paragraph
  with: *"You run in a worktree that shares the project board (bd discovers it via the git common
  dir). Read your context with `bd show <id>` / `bd comments <id>`. On finish, post your handoff
  with `bd comment <id> "…" --actor=<role>` and advance status (`bd update`/`bd close
  --actor=<role>`)."*
- `engineer`: writes its own handoff + opens the PR (already does the PR).
- `reviewer`: runs `bd close --actor=reviewer` itself on pass.
- `planner`: runs its own `bd create`/`bd dep add --actor=planner`.
- Keep each role's handoff block + checklist. Use **"the project board,"** never "embedded."

**C. `templates/CLAUDE.bench.md`** (~29–31)
- Rewrite the bullet to: *"Every agent runs `bd` directly against the shared project board with
  `--actor=<role>`; the orchestrator owns routing, integration, and the bounce cap, not courier
  duty."* Bumps the content hash → SessionStart drift-check nudges existing projects to re-run
  `/bench:init`. Intended.

**D. `commands/doctor.md` + `skills/beads-health-check/SKILL.md`** (light)
- doctor: add a one-liner confirming a worktree can reach the board (`bd show` from a temp worktree)
  and report `BENCH_BOARD_MODE`. **Do NOT use `bd doctor`** for this — it returns *"not yet
  supported in embedded mode."* health-check: note embedded is the supported default; server is the
  scale-up path. **Do not flag `.beads/embeddeddolt/.lock` as stale** — that file is always present
  in normal idle operation (noms), not a wedged-lock signal.

### 11.4 The C migration, preserved

When/if scale demands it (dozens of high-frequency concurrent writers — *not* your stated scale),
flip to C with **zero agent/skill-contract changes**:
1. `install-bd.sh` also installs pinned `dolt`; add `beads-server-up.sh`/`-down.sh` (§4), gated on
   `BENCH_BOARD_MODE=server`.
2. Set `sync-mode: dolt-native`, `bd init --server`.
3. Agents are unchanged — "read the board / write with `--actor`" is already true against a server.

**Caveat — C is not "zero-risk," only "zero agent-edits."** The agent/skill contract is unchanged,
but server-mode's *lifecycle* has open reliability bugs: nondeterministic auto-start with
stale-lock/process races leaving the tracker unreachable (GH#3392, open), a doctor restart loop
spawning zombie dolt procs (GH#2636), and stale noms `LOCK` after doctor (GH#1925). The C transport
needs hardening; it is not a flip-and-forget switch.

**Trigger to flip:** sustained handoff-write latency from **driver serialization** (≈540ms/op at
150-way in the adversarial re-test) becoming material, or a move to autonomous self-claim from a
shared queue.

### 11.5 Phases & acceptance

1. **Skill rewrite (A)** — orchestrator no longer couriers; agents own their bd writes. *Accept:* a
   dry-run dispatch description shows the agent reading `bd show` and writing its own `--actor`
   handoff.
2. **Agent defs + template (B, C)** — propagate the contract. *Accept:* no agent def contains the
   word "ZERO bd" or "embedded single-writer"; all say "the project board."
3. **doctor/health-check (D)** — *Accept:* `/bench:doctor` reports board reachability + mode.
4. **End-to-end on a scratch board** — reuse the §9 spike harness: one real bead through
   engineer→qa→reviewer, each role writing its own `--actor` comment, orchestrator closing only via
   reviewer's pass. *Accept:* `bd show` renders the full `engineer → qa → reviewer` chain with
   correct actors, no orchestrator-relayed writes.

### 11.6 Risks

- **Bounce-cap visibility.** The cap is orchestrator-enforced (gates can't see history). With agents
  writing status directly, the orchestrator must still **read** `bd show` after each return to count
  round-trips. Keep that read in the loop.
- **Drift-hash churn.** Changing `CLAUDE.bench.md` nudges every installed project to re-run
  `/bench:init`. Call it out in the changelog.
- **Version-fragility is load-bearing, not incidental.** The concurrency *safety mechanism changed
  within the pinned line*: bd 1.0.4 removed the embedded flock (PR #3614) and now relies on the
  Dolt driver's internal serialization, with the GH#2571 concurrent nil-deref panic class **latent**
  behind it. So re-running the §9 spike on **any** `bd_version` bump is mandatory, not a nicety —
  a driver regression could resurface #2571 under exactly our access pattern. The pin has since
  moved to **1.1.0**, gated on the 2026-07-06 re-spike (Bench-nfh: migration rehearsal clean,
  GH#2571 concurrency gate PASS, git-common-dir worktree sharing intact); the re-spike-before-bumping
  rule stands for any future bump.
- **Two git-tracked JSONLs, not one.** `issues.jsonl` *and* `interactions.jsonl` both carry the
  stale-snapshot/merge-resurrection profile (§11.3.A). Any worktree `.beads/` commit is a hazard.

## 12. Explicitly out of scope

- **DoltHub** as a remote (we stay on GitHub `refs/dolt/*`). Could be added later purely as a
  browsable mirror without touching this design.
- **Topology C** (a web-exposed, always-on shared server for live cross-machine boards) — needs
  auth/TLS and is a different deployment.
- **Shared multi-project server** (`~/.beads/shared-server/`) — a later optimization.
