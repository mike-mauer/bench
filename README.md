# Bench

A beads-backed **multi-agent orchestration harness** for Claude Code, packaged as an
installable, upgradeable plugin. Drop it into any project to get:

- A **planner → engineer → qa → reviewer** agent pipeline (with optional `data-eng` and
  `design-reviewer` specialist roles), driven by the main session as orchestrator.
- The **orchestration playbook** as an on-demand skill (`bench-orchestrator`): how to
  decompose work into beads, dispatch role Workers, relay handoffs, enforce the bounce cap,
  and isolate code Workers in git worktrees.
- **Beads/Dolt** issue tracking wired into the session lifecycle — the harness depends on the
  [`beads`](https://github.com/gastownhall/beads) plugin and supplies the `bd` binary at a
  pinned version, plus cold-start board rehydration, worktree hygiene, and a session-end guard.
- A **`beads-health-check`** maintenance skill.
- A one-time **`/bench:init`** that injects the always-on orchestrator rules into your
  project's `CLAUDE.md`, initializes the board, and de-dupes hooks — the things a plugin
  can't do passively.
- **`/bench:new-agent`** to mint your own pipeline roles beyond the built-ins — the
  orchestrator discovers and routes to them automatically (see below).

## Why a plugin + a marketplace?
A Claude Code plugin can ship agents, skills, commands, and hooks, and **upgrades cleanly**
(`claude plugin update bench`). But two things must be done per-project by a command, because
a plugin can't touch them passively: **appending to `CLAUDE.md`** (a plugin's own CLAUDE.md is
never loaded as project context) and **initializing `.beads/` / project settings**. That's the
job of `/bench:init`.

## Install
```bash
# 1. Prerequisite: the beads plugin (Bench uses its `bd prime` hooks). Install it
#    first — Bench does NOT auto-install it (a cross-marketplace dependency can't be
#    declared reliably; see notes below).
claude plugin marketplace add gastownhall/beads
claude plugin install beads@beads-marketplace

# 2. Add this marketplace + install Bench
claude plugin marketplace add mike-mauer/bench
claude plugin install bench@bench            # user scope (default); --scope project to share via the repo

# 3. One-time per-project setup
/bench:init
#    optional specialist roles:
/bench:init --with data-eng,design-reviewer --prefix Acme
```

> **Note on the beads dependency.** Bench relies on the `beads` plugin for its
> `bd prime` hooks, but does **not** declare it in `plugin.json` `dependencies`:
> a bare `{ "name": "beads" }` resolves against Bench's *own* marketplace
> (`beads@bench`, which doesn't exist) and blocks enablement. Install `beads`
> yourself first — it's a standard plugin most projects already have.

## Upgrade
```bash
claude plugin update bench
```
Agents, skills, hooks, and scripts refresh immediately. The `CLAUDE.md` orchestrator block is
versioned by content hash — a SessionStart drift check warns when it's stale, and re-running
`/bench:init` refreshes it in place.

## Verify
```bash
/bench:doctor            # read-only: bd version, plugins active, CLAUDE.md block fresh, hooks
claude plugin validate ./plugins/bench --strict
```

## What ships in the plugin
```
plugins/bench/
├── agents/            planner · engineer · qa · reviewer        (auto-registered)
├── agents-optional/   data-eng · design-reviewer               (templated; installed via --with)
├── skills/            bench-orchestrator · beads-health-check
├── commands/          init · doctor                            (/bench:init, /bench:doctor)
├── hooks/hooks.json   SessionStart: install-bd, worktree-reap, drift-check
│                       SessionEnd: stop-guard, cloud-push   (NOT bd prime — from beads dep)
├── scripts/           the hook implementations
└── templates/         CLAUDE.bench.md · custom-agent.md  (block + custom-role scaffold)
```

## Custom roles
The built-in pipeline is `planner → engineer → qa → reviewer`, with optional `data-eng` /
`design-reviewer`. When a concern needs its own owner or gate, scaffold a **custom role**:
```bash
/bench:new-agent api-reviewer --kind gate --sits 'after qa, before reviewer'
/bench:new-agent perf --kind builder --model opus
```
This writes a Bench-compliant Worker to `.claude/agents/<name>.md` (handoff block,
`--actor=<name>` attribution, direct `bd` access, and a self-declared `## Routing` block);
fill its `<<FILL: ...>>` placeholders and commit. **The orchestrator discovers roles by
listing `.claude/agents/`** and routes to each per its `description` + `## Routing` — so a
custom role is wired into the pipeline by its mere presence, with **nothing to add to the
managed `CLAUDE.md` block** (which is regenerated on every `/bench:init`). That is the
durable fix for "I added a role but it never gets routed to": the agent def *is* the
registration, and it survives plugin refreshes because it's project-owned.

## Configuration
`bd_version` (plugin userConfig, default `1.0.4`) — the beads CLI version the SessionStart
hook installs into the persistent plugin data dir. Override only if you need a different
release; an existing `bd` already on your `PATH` is always respected.

## License
MIT
