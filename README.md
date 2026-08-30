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

No local machine — installing from a Claude Code cloud/web session? `claude plugin install`
doesn't survive there. Use the cloud install script instead (details below):
```bash
curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
```

> **Note on the beads dependency.** Bench relies on the `beads` plugin for its
> `bd prime` hooks, but does **not** declare it in `plugin.json` `dependencies`:
> a bare `{ "name": "beads" }` resolves against Bench's *own* marketplace
> (`beads@bench`, which doesn't exist) and blocks enablement. Install `beads`
> yourself first — it's a standard plugin most projects already have.

## Cloud / web sessions (Claude Code on the web)
`claude plugin install` writes enablement to **user scope** (`~/.claude/settings.json`), which
**does not travel to a cloud session** — Claude Code on the web runs in a fresh container that
clones only the repo. Without committed config, a web session has no Bench: the
`planner`/`engineer`/`qa`/`reviewer` **subagent identities never register** and the SessionStart
hooks don't fire (so `bd` isn't installed either). That's the usual "subagent identities don't
exist" blocker in the cloud.

`/bench:init` (Step 3b) fixes this by committing the plugin enablement to the repo's
`.claude/settings.json` — web sessions load plugins **only** from there:
```json
{
  "extraKnownMarketplaces": {
    "bench": { "source": { "source": "github", "repo": "mike-mauer/bench" } },
    "beads-marketplace": { "source": { "source": "github", "repo": "gastownhall/beads" } }
  },
  "enabledPlugins": [
    { "marketplace": "beads-marketplace", "plugin": "beads" },
    { "marketplace": "bench", "plugin": "bench" }
  ]
}
```
Commit that file and your next web session bootstraps the marketplace, registers the four
subagent roles, and runs the hooks. `/bench:doctor` (check 2) flags its absence.

### Installing from inside a cloud session (`cloud-install.sh`)
The catch: `/bench:init` writes that config, but it ships **inside the plugin that isn't
loaded** — so from a cloud session on a project that has never had Bench, there is nothing to
run. The cloud install script breaks that chicken-and-egg from a plain shell:

```bash
curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
# options go after `-s --`:
curl -fsSL <same url> | bash -s -- --with data-eng,design-reviewer
```

It writes the repo-scoped `.claude/settings.json` above (merged — unrelated keys, hooks and
permissions survive; entries never duplicate), installs the pinned `bd` into `~/.local/bin` so
the **current** session has it, injects the managed `CLAUDE.md` orchestrator block with the same
marker + hash `/bench:init` uses, sets `.beads/.gitattributes` to `merge=union` if a board
exists, and copies any `--with` roles. It never touches user scope and never commits.

```
--project-dir <path>   project to install into (default: git toplevel)
--with <roles>         data-eng, design-reviewer
--no-bd | --no-claudemd | --dry-run | --help
BENCH_REPO / BENCH_REF / BEADS_REPO / BENCH_BIN_DIR   (env; BENCH_REPO for a fork)
```

Then **commit, start a new session** (plugins load at session start, from the committed
settings) and run `/bench:init` — it creates the beads board, the one thing the script
deliberately leaves alone, since it needs an issue prefix and a Dolt remote decision. Re-running
the script is safe and idempotent; a failure to write `.claude/settings.json` — the step that
actually enables Bench — is the one condition that exits non-zero, printing the snippet to merge
by hand. From a checkout you already have, run it directly instead of over curl:
`bash plugins/bench/scripts/cloud-install.sh`.

### No more `.beads/*.jsonl` merge conflicts
The board's durable state lives in the Dolt history synced via `refs/dolt/data` (cell-level
merge — it never text-conflicts). `.beads/issues.jsonl` and `.beads/interactions.jsonl` are
git-tracked but are **one-way, derived exports**; when several sessions — especially ephemeral
cloud containers — each re-export them, they collide on the same lines and produce spurious
merge conflicts. `/bench:init` (and, for existing installs, the SessionStart bootstrap) now
writes a `.beads/.gitattributes` that marks them `merge=union` — a built-in git strategy (no
per-machine driver to register, so it works on fresh clones). Git keeps both sides instead of
raising conflict markers, and the next `bd export` rewrites the file clean from the authoritative
board. **Never hand-resolve these files** — trust the board and re-export.

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
│                       Stop: cloud-push (incremental)           (web-only bead persist)
│                       SessionEnd: stop-guard, cloud-push (final)   (NOT bd prime — from beads dep)
├── scripts/           the hook implementations + cloud-install.sh (curl-able installer)
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
`bd_version` (plugin userConfig, default `1.1.0`) — the beads CLI version the SessionStart
hook installs into the persistent plugin data dir. Override only if you need a different
release; an existing `bd` already on your `PATH` is always respected.

## License
MIT
