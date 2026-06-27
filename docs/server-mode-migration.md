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

1. **Does `bd dolt start` need a separate `dolt` binary?** Embedded mode uses bd's bundled Dolt
   engine; server mode needs a running `dolt sql-server`. Verify whether `bd dolt start` spins
   one up from bd's own bundle or requires `dolt` on PATH. If the latter, `install-bd.sh` must
   also install `dolt`. **Blocking — settle first.**
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
- **`scripts/install-bd.sh`** — if Q1 resolves "separate dolt needed," add a pinned `dolt`
  install alongside `bd`. After bd lands (line ~91), start the server in dolt-native mode (or
  call a new `beads-server-up.sh`).
- **NEW `scripts/beads-server-up.sh`** — idempotent: if no server on the configured port, set
  `.beads/config.yaml` `sync-mode: dolt-native`, write/verify `.beads/metadata.json`, start
  `bd dolt start` (or `dolt sql-server`), wait for readiness, best-effort exit 0.
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

## 7. Explicitly out of scope

- **DoltHub** as a remote (we stay on GitHub `refs/dolt/*`). Could be added later purely as a
  browsable mirror without touching this design.
- **Topology C** (a web-exposed, always-on shared server for live cross-machine boards) — needs
  auth/TLS and is a different deployment.
- **Shared multi-project server** (`~/.beads/shared-server/`) — a later optimization.
