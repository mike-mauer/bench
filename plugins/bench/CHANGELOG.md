# Changelog

All notable changes to the Bench plugin are documented here. Bump `version` in
`.claude-plugin/plugin.json` on every release so `claude plugin update` picks it up.

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
