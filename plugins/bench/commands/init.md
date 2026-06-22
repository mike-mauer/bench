---
name: init
description: One-time per-project setup for the Bench harness — injects the orchestrator rules into CLAUDE.md, initializes the beads board, fixes settings, and optionally installs the data-eng / design-reviewer roles. Re-run after `claude plugin update bench` to refresh the CLAUDE.md block.
argument-hint: "[--with data-eng,design-reviewer] [--prefix <IssuePrefix>]"
---

# /bench:init — initialize the Bench harness in this project

You are setting up the Bench harness in the current project. A plugin cannot edit a
project's `CLAUDE.md`, initialize `.beads/`, or change project settings on its own — that
is what this command does. Work through the steps below, reporting what you changed.

Arguments (from `$ARGUMENTS`):
- `--with <roles>` — comma-separated optional roles to install: `data-eng`, `design-reviewer`.
- `--prefix <IssuePrefix>` — beads issue prefix for a brand-new board (e.g. `Acme`).

Plugin paths are pre-substituted: the template is at `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md`
and optional agents at `${CLAUDE_PLUGIN_ROOT}/agents-optional/`.

## Step 1 — Inject the orchestrator rules into CLAUDE.md (versioned marker block)
The block is delimited so it can be refreshed idempotently on future runs.

1. Compute the template's 8-char content hash (same method the drift-check hook uses):
   ```bash
   if command -v sha256sum >/dev/null 2>&1; then H=$(sha256sum "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md" | cut -c1-8)
   else H=$(shasum -a 256 "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md" | cut -c1-8); fi; echo "$H"
   ```
2. Build the block: a `<!-- BEGIN BENCH v:1 hash:$H -->` line, then the **verbatim contents**
   of `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md`, then a `<!-- END BENCH -->` line.
3. If `CLAUDE.md` doesn't exist, create it with this block. If it exists **and already has a
   `<!-- BEGIN BENCH ... -->` … `<!-- END BENCH -->` block**, replace that block in place
   (preserving everything else). Otherwise, append the block at the end. **Never** disturb
   other content (including any existing `<!-- BEGIN BEADS INTEGRATION -->` block).

## Step 2 — Initialize the beads board
1. If a `.beads/` directory already exists, skip init; just confirm `bd ready` works.
2. Otherwise run `bd init` (the beads plugin provides `bd`). Set the issue prefix from
   `--prefix` if given, else ask the user for a short PascalCase prefix. Ensure
   `.beads/issues.jsonl` is created and staged for commit.
3. Do NOT configure a GitHub sync token here — leave it env-only (the health-check skill
   explains why). Do NOT run `bd github sync`.

## Step 3 — Fix project settings (de-dupe hooks)
The Bench plugin and the `beads` plugin it depends on both supply SessionStart behavior. If
this project's own `.claude/settings.json` has a hand-rolled `SessionStart` hook running
`bd prime` (or `worktree-reap`, or a beads bootstrap script), it now **double-fires** with the
plugin-provided hooks. Inspect `.claude/settings.json` and **remove the now-duplicate
`bd prime` SessionStart entry** (and any hand-rolled worktree-reap / beads-bootstrap entries
the plugin now provides). Leave unrelated hooks untouched. Show the user the diff before saving.

## Step 4 — Permissions allowlist (optional, ask first)
Offer to add common harness commands to `.claude/settings.local.json` `permissions.allow`
so the orchestrator isn't prompted constantly — e.g. `Bash(bd *)`, `Bash(git add:*)`,
`Bash(git commit:*)`, `Bash(git push:*)`, `Bash(gh pr *)`. Only add what the user approves.

## Step 5 — Optional roles (`--with`)
For each role in `--with`:
1. Copy `${CLAUDE_PLUGIN_ROOT}/agents-optional/<role>.md` → `.claude/agents/<role>.md`.
2. Tell the user it contains `<<FILL: ...>>` placeholders (and, for `data-eng`, possibly a
   project-specific data tool to add to the `tools:` frontmatter) that must be filled in with
   this project's specifics before the role is used. Offer to help fill them now.

## Step 6 — Report
Summarize: CLAUDE.md block (added/refreshed, with the version+hash), beads board state +
prefix, settings changes made, permissions added, and which optional roles were installed.
Remind the user to commit the changes (`CLAUDE.md`, `.beads/`, `.claude/`).
