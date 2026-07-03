# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->


## Build & Test

This repo is the source of the Bench plugin — there is no app to build. Quality gates:

```bash
claude plugin validate ./plugins/bench --strict   # plugin manifest/structure validation
shellcheck plugins/bench/scripts/*.sh             # lint all hook scripts
bats tests/                                       # script tests (tests/ is landing on a parallel branch)
```

## Architecture Overview

This repo is a Claude Code plugin **marketplace** serving a single plugin: `.claude-plugin/marketplace.json` points at `./plugins/bench`. Inside `plugins/bench/`, `agents/` holds the core pipeline roles (planner, engineer, qa, reviewer) and `agents-optional/` the opt-in specialists (data-eng, design-reviewer) that `/bench:init --with` copies into a consuming project. `skills/` carries the orchestrator playbook and the beads health-check skill, and `commands/` the `/bench:*` slash commands (init, doctor, new-agent). `hooks/hooks.json` wires session lifecycle events to the shell scripts in `scripts/` (bd install, worktree reaping, CLAUDE.md drift check, session-end guard, cloud push). `templates/` holds the CLAUDE.md orchestrator block that `/bench:init` injects into consuming projects, plus the custom-agent scaffold.

## Conventions & Patterns

- **Hook scripts are best-effort:** every code path exits 0 — a hook must never block a session. They use `set -uo pipefail` (never `-e`) and log through a `log()` helper that prefixes each line (e.g. `[worktree-reap] …`).
- **Actor attribution:** agent and skill docs pass `--actor=<role>` inline on every bd write — `BEADS_ACTOR` does not survive across shells.
- **Managed CLAUDE.md block:** the orchestrator block shipped in `templates/CLAUDE.bench.md` is versioned by an 8-char content hash (`<!-- BEGIN BENCH v:N hash:XXXX -->`, computed by `scripts/bench-hash.sh`) and managed by `/bench:init`; the drift-check hook warns when a project's copy goes stale.
