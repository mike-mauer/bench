# Changelog

All notable changes to the Bench plugin are documented here. Bump `version` in
`.claude-plugin/plugin.json` on every release so `claude plugin update` picks it up.

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
