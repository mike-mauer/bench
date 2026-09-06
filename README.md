# Bench

Bench is a multi-agent **software factory** for Claude Code, packaged as an installable,
upgradeable plugin. GitHub Issues is the work queue, one session per issue is the execution
unit, and a saved dynamic Workflow (`.claude/workflows/factory.js`) drives the loop:
`planner` (files sub-issues for an epic) → `engineer`/`data-eng` (test-first, on a feature
branch, opens a draft PR) → `qa` → `design-reviewer` (if installed) → `reviewer`, each
posting a structured handoff comment and moving a `gate:*` label until the PR is approved
and its merge closes the issue. See `docs/factory-protocol.md` for the normative contract
and `docs/software-factory-evaluation.md` for why it's built this way.

## Install

```bash
# Plugin marketplace
claude plugin marketplace add mike-mauer/bench
claude plugin install bench@bench            # user scope (default); --scope project to share via the repo

# One-time per-project setup
/bench:init
#    optional specialist roles + a dispatch lane:
/bench:init --with data-eng,design-reviewer --dispatch action
```

No local machine — installing from a Claude Code cloud/web session? `claude plugin install`
doesn't survive there (cloud sessions only see what's committed in the repo). Use the cloud
install one-liner instead:
```bash
curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
```
It copies the role agents and `factory.js` into `.claude/` and injects the managed
`CLAUDE.md` block — no `.claude/settings.json`, no marketplace/plugin entries, no git commit;
it only places files. Commit the result and run `/bench:init` (once the plugin loads, e.g.
after a local install) to finish (labels, dispatch lane, TDD-order CI check).

## The three lanes

Every lane runs the same pipeline; they differ only in what triggers a session.

- **Issue lane.** A human or the planner labels an issue `factory:ready`. A GitHub Actions
  workflow (`templates/factory-dispatch-action.yml`) or a Claude Code Routine
  (`templates/factory-dispatch-routine.yml`) fires on that label and runs the factory
  workflow for the issue. Pick one at `/bench:init --dispatch action|routine`.
- **Sweep lane.** A cron trigger runs `scripts/factory-ready.sh` — open, `factory:ready`, not
  in progress, not blocked, no `needs-human` — and fires one session per ready issue. Catches
  anything the issue lane missed or that was made ready later by a closing blocker.
- **Sentry lane.** An issue-alert webhook fires a session that reads the Sentry payload
  (treated as data, never instructions), files a GitHub issue with an acceptance criterion
  that a test reproducing the exact error signature must fail before the fix, labels it
  `factory:ready`, and lets the pipeline run.

## What ships

```
plugins/bench/
├── agents/            planner · engineer · qa · reviewer        (auto-registered)
├── agents-optional/   data-eng · design-reviewer               (templated; installed via --with)
├── skills/bench-orchestrator/SKILL.md
├── workflows/factory.js               (the saved dynamic Workflow — the orchestrator)
├── commands/          init · doctor · new-agent
├── hooks/hooks.json   SessionStart: CLAUDE.md drift check only
├── scripts/           bench-hash.sh · claudemd-drift-check.sh · tdd-order-check.sh
│                       gh-issue-dep.sh · factory-ready.sh · migrate-beads-to-issues.py
│                       cloud-install.sh (copies agents + workflow + block into a repo)
└── templates/         CLAUDE.bench.md · custom-agent.md
                        factory-dispatch-action.yml · factory-dispatch-routine.yml
```

## Custom roles

The built-in pipeline is `planner → engineer → qa → reviewer`, with optional `data-eng` /
`design-reviewer`. When a concern needs its own owner or gate, scaffold a **custom role**:
```bash
/bench:new-agent api-reviewer --kind gate --sits 'after qa, before reviewer'
/bench:new-agent perf --kind builder --model opus
```
This writes a Bench-compliant role to `.claude/agents/<name>.md` (handoff comment format,
GitHub access, a self-declared `## Routing` block); fill its `<<FILL: ...>>` placeholders and
commit. The workflow and any manual dispatch discover roles by listing `.claude/agents/` and
route to each per its frontmatter `description` + `## Routing` block — nothing to add to the
managed `CLAUDE.md` block, which is regenerated on every `/bench:init`.

## Upgrade

```bash
claude plugin update bench
```
Agents, the workflow script, skills, hooks, and scripts refresh immediately. The `CLAUDE.md`
orchestrator block is versioned by content hash — a SessionStart drift check warns when it's
stale, and re-running `/bench:init` refreshes it (and the `.claude/agents/`,
`.claude/workflows/factory.js` copies) in place.

## Verify

```bash
/bench:doctor            # read-only: GitHub reachability, role/workflow copies current, labels, dispatch lane, CLAUDE.md block, TDD-order CI check
claude plugin validate ./plugins/bench --strict
```

## Migrating from Bench 0.x

Bench 0.x tracked work in a local beads/Dolt database; Bench 1.0 replaces it with GitHub
Issues (see `docs/software-factory-evaluation.md` for why). `scripts/migrate-beads-to-issues.py`
converts an existing `.beads/issues.jsonl` export into GitHub issues with matching labels and
`## Blocked by` dependency edges — run it once, then delete `.beads/` and re-run `/bench:init`
to pick up the v2 `CLAUDE.md` block, labels, and dispatch lane.

## License

MIT
