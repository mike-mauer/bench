# Changelog

All notable changes to the Bench plugin are documented here. Bump `version` in
`.claude-plugin/plugin.json` on every release so `claude plugin update` picks it up.

## Unreleased — install Bench from inside a cloud session (`cloud-install.sh`)
- **New `scripts/cloud-install.sh`**, curl-able from a Claude Code cloud/web session:
  `curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash`.
- **Closes the bootstrap chicken-and-egg.** `claude plugin install` writes user scope, which a
  cloud container never sees; the fix is the repo-scoped `.claude/settings.json` — but the command
  that writes it (`/bench:init`) ships inside the plugin that isn't loaded. A project that has
  never had Bench therefore could not be set up from the cloud at all. The script does it from a
  plain shell, with no Claude CLI.
- **What it writes** (all idempotent, all repo-scoped, nothing committed): the
  `extraKnownMarketplaces` + `enabledPlugins` entries **merged** into any existing
  `.claude/settings.json` (unrelated keys, hooks and permissions preserved; entries never
  duplicated); the pinned `bd` into `~/.local/bin` so the **current** session has it (the
  SessionStart hook only runs from the next one); the managed `CLAUDE.md` orchestrator block; and
  `.beads/.gitattributes` (`merge=union`) when a board exists. `--with data-eng,design-reviewer`
  installs the optional roles.
- **Single-sources what it reuses:** the marker hash comes from the bundled `scripts/bench-hash.sh`
  (fetched with the template when run over curl), so `/bench:init`, the drift-check hook and this
  script can never disagree and warn "stale"; the `bd` pin is read from `plugin.json`'s
  `bd_version` default rather than re-hardcoded.
- **Refuses rather than clobbers:** an object-shaped `enabledPlugins`, an unparseable settings
  file, or a `CLAUDE.md` with a `BEGIN BENCH` marker and no `END BENCH` are left untouched with
  the snippet to merge by hand. Unlike the hook scripts (which must always exit 0), this one is
  user-invoked: a failed settings write — the step that actually enables Bench — exits 1.
- `--dry-run` reports without writing; `BENCH_REPO`/`BENCH_REF` install from a fork or branch.
- Board creation is deliberately left to `/bench:init` (it needs an issue prefix and a Dolt remote
  decision). Covered by `tests/cloud_install.bats`.

## Unreleased — no more `.beads/*.jsonl` merge conflicts in cloud containers
- **Fix: parallel / ephemeral cloud sessions no longer collide on the beads JSONL.**
  `.beads/issues.jsonl` and `.beads/interactions.jsonl` are git-tracked but are one-way,
  **derived** exports of the Dolt board (the durable source of truth is `refs/dolt/data`, which
  cell-merges and never text-conflicts). Every session re-exports them, so multiple cloud
  containers produced spurious merge conflicts on the same lines on each commit.
- **`.beads/.gitattributes` now marks `*.jsonl merge=union`** — a **built-in** git merge
  strategy (no `.git/config` driver to register, so it survives fresh clones / cold containers).
  Git keeps both sides instead of raising conflict markers; the next `bd export` rewrites the file
  clean from the authoritative board. No board data can be lost this way — the JSONL is derived.
- **Applied on three surfaces:** `/bench:init` (Step 2) writes + commits it for new setups;
  `scripts/beads-bootstrap.sh` idempotently auto-writes it on SessionStart so **existing installs
  pick up the fix without re-running `/bench:init`**; and this repo self-hosts it.
- **`bench-orchestrator` skill:** the JSONL-resurrection warning now notes union-merge makes the
  conflict auto-resolve, while keeping the "Workers don't commit `.beads/`; re-export from the
  main tree" discipline (union-merge can leave a transient stale row until the next export).
- No `CLAUDE.bench.md` change — the managed block is untouched, so installed projects do **not**
  need to re-run `/bench:init` for this fix (bootstrap auto-heals it); re-running init is only
  needed to commit `.beads/.gitattributes` up front.

## Unreleased — cloud/web sessions register the subagent roles
- **Fix: the pipeline is usable in Claude Code on the web.** A local `claude plugin install`
  records enablement in user-scope `~/.claude/settings.json`, which never reaches a cloud
  session (a fresh container that clones only the repo). The result: the `planner`/`engineer`/
  `qa`/`reviewer` **subagent identities never register** ("subagent identities don't exist") and
  the SessionStart hooks don't fire, so `bd` isn't installed either — the whole harness is offline.
- **`/bench:init` now commits web enablement (Step 3b).** In addition to de-duping hooks, init
  writes `enabledPlugins` (`bench` + its `beads` dependency) and the matching
  `extraKnownMarketplaces` sources into the project's `.claude/settings.json` — the only place a
  web session loads plugins from. Merges into existing keys; a no-op for local sessions.
- **`/bench:doctor` check 2 flags a missing web-enablement config**, naming it as the usual cause
  of the cloud "subagent identities don't exist" symptom.
- **This repo now self-hosts Bench in the cloud** via its own committed `.claude/settings.json`.
- README gains a **Cloud / web sessions** section documenting the config. Installed projects
  should re-run `/bench:init` to pick up Step 3b; no `CLAUDE.bench.md` change.

## 0.3.2 — context belongs on the bead, not the dispatch prompt
- **Orchestrator: a context-placement rule + tripwire on the dispatch step.** Step 5 now names
  the three kinds of context and their homes — **spec** (scope, acceptance criteria, security/
  correctness boundary, non-goals) on the bead **description**, **pipeline** (prior handoffs, env
  notes) in bead **comments**, **runtime/operational** (facts that didn't exist at plan time) in
  the prompt — and a tripwire: if you're about to paste `## Scope`/`## Hard rules`/acceptance
  criteria/the handoff format into a Worker prompt, stop and enrich the bead instead. The quality
  rationale: a boundary stated only in the prompt is invisible to the `reviewer` that exists to
  enforce it, because the prompt evaporates and the bead is what every downstream gate reads.
- **Planner: an explicit self-sufficiency bar (decomposition rule 9).** A bead is done when a
  Worker can start from `bd show` + `bd comments` + its role def alone, with nothing in the prompt
  but id + role. Spec-context the builder needs goes in the description; if the orchestrator has to
  explain scope at spawn time, the bead was underspecified — a bug in the planner's output.
- **Health-check: `bd lint` now frames missing spec sections as a self-sufficiency failure**,
  flagging underspecified beads to enrich before dispatch rather than patch in a one-shot prompt.
- No `CLAUDE.bench.md` change — installed projects do **not** need to re-run `/bench:init`; pick up
  the updated planner/orchestrator/health-check guidance via `claude plugin update`.

## 0.3.1 — durable bead writes (no more silent reversion)
- **Fix: bead writes no longer silently revert on web sessions.** Closing a bead wrote
  only to the local embedded Dolt DB; the single best-effort SessionEnd push that was
  meant to carry it to the remote "cold board" swallowed its own failure, so if the
  ephemeral container was reclaimed before SessionEnd — or the push just failed — the
  write never landed. The next cold container then rehydrated (`beads-bootstrap.sh`)
  from the **stale** remote and the write reverted (beads snapped back to `open` with
  old timestamps). Two changes close this:
  - **`beads-cloud-push.sh` is now push-FIRST with retry.** It pushes first (the live
    container holds the good state; pulling a stale remote first is what merged the old
    rows back), retries with exponential backoff, and only on a non-fast-forward
    rejection does it pull+push to reconcile. A persistent failure now writes a durable
    `.beads/.cloud-push-failed` marker and logs loudly instead of exiting 0 in silence.
  - **New cloud-only `Stop` hook** runs the same script in `incremental` mode — a cheap,
    push-only persist after every main-agent turn. Closes now reach the remote within
    seconds, so a later cold-start has no stale state to revert to. Local sessions are
    unaffected (still gated on `CLAUDE_CODE_REMOTE=true`).
- **Health-check: closure-consistency now scans by ID convention, not edges.** The
  "closed epic with open children" check read `parent-child` edges — exactly what a
  board rebuild drops — so it returned a false "ok" while an orphaned child sat
  `in_progress` under a closed epic. It now groups by the dotted-ID convention
  (`epic.N`) across **all** statuses (`bd list` defaults to open-only), catching orphans
  the edge-based progress bars can't see. The `.cloud-push-failed` marker is also a
  flagged condition.
- No `CLAUDE.bench.md` change — installed projects do **not** need to re-run `/bench:init`.

## 0.3.0 — custom roles (`/bench:new-agent`)
- **New command `/bench:new-agent <name>`.** Scaffolds a project-owned, Bench-compliant
  Worker into `.claude/agents/<name>.md` from a generic template
  (`templates/custom-agent.md`) — handoff block, `--actor=<name>` attribution, direct bd
  access, worktree note, and a self-declared `## Routing` block. Flags: `--kind
  builder|gate`, `--model`, `--tools`, `--sits`. Reserved names (built-ins + the two
  optional roles + `orchestrator`) are rejected; an existing file is never clobbered.
- **The pipeline role set is now open.** The orchestrator discovers roles by listing
  `.claude/agents/` rather than from a fixed list: any agent there is routable, placed per
  its frontmatter `description` + `## Routing`. This fixes the gap where a hand-added role
  was never routed to because the managed CLAUDE.md block didn't name it — and because
  discovery is via the (project-owned) agent defs, custom routing **survives `/bench:init`
  refreshes** with no managed-block edits. Documented in the `bench-orchestrator` skill
  (new "Custom / project-defined roles" section + routing-table row).
- `/bench:doctor` now lists custom roles and flags any with unfilled `<<FILL>>`s or an
  incomplete `## Routing` block.
- **Action required — re-run `/bench:init`.** The `CLAUDE.bench.md` block gained a
  "Custom roles are part of the pipeline" clause, so its content hash bumped; the
  SessionStart drift-check will flag installed projects. Re-run `/bench:init` to refresh.

## 0.2.0 — agents run bd directly (Option B′)
- **Access-model change.** Replaced the "subagents run ZERO bd" rule with direct board access:
  every role runs `bd` against the one shared embedded board, reads its context from the bead
  (`bd show` / `bd comments`), and records its own handoff with `--actor=<role>`. The orchestrator
  no longer couriers context or relays writes — it owns decomposition, routing, model selection,
  the bounce cap, and integration. Verified safe on the pinned **bd 1.0.4** (worktrees share the
  canonical board via git-common-dir discovery; the Dolt driver serializes concurrent writes — the
  embedded flock was removed upstream in 1.0.4).
- **Action required — re-run `/bench:init`.** The `CLAUDE.bench.md` block changed, so its content
  hash bumped; the SessionStart drift-check will flag installed projects. Re-run `/bench:init` to
  refresh the CLAUDE.md orchestrator block.
- `planner` now files its own beads (`bd create` / `bd dep add --actor=planner`); `reviewer` closes
  the bead itself (`bd close --actor=reviewer`).
- `/bench:doctor` reports the board engine mode and documents the access model.
- Worktree guidance: use plain `git worktree add` (not `bd worktree create`, which rejects `.beads`
  under `$HOME`); the `issues.jsonl` / `interactions.jsonl` resurrection warning is retained — both
  are git-tracked + pre-commit-exported while the board is embedded.
- Docs: `docs/server-mode-migration.md` records the design rationale, the concurrency spike, the
  adversarial review, and the preserved Option C (Dolt server mode) migration path.

## 0.1.1 — fix enablement blocker
- Removed the `dependencies: [{ name: "beads" }]` declaration. A bare dependency
  name resolves against Bench's own marketplace (`beads@bench`, nonexistent), which
  made `plugin enable` fail with "bench depends on beads@bench, which is not
  installed." beads is now documented as a prerequisite to install separately.

## 0.1.0 — initial extraction
- Core agents: `planner`, `engineer`, `qa`, `reviewer` (genericized from the Beacon harness).
- Optional templated roles: `data-eng`, `design-reviewer` (installed via `/bench:init --with`).
- Skills: `bench-orchestrator` (the dispatch playbook) and `beads-health-check`.
- Commands: `/bench:init` (CLAUDE.md block + `bd init` + hook de-dup + optional roles) and
  `/bench:doctor` (read-only install health check).
- Hooks: SessionStart `install-bd` / `worktree-reap` / `claudemd-drift-check`; SessionEnd
  `beads-stop-guard` / `beads-cloud-push`. Depends on the `beads` plugin for `bd prime`.
- Configurable `bd_version` (default pinned `1.0.4`), installed into the persistent plugin
  data dir; an existing `bd` on PATH is respected.
