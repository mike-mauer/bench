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

1. Compute the template's 8-char content hash (via the canonical helper the drift-check
   hook and `/bench:doctor` also use, so all three always agree on the format):
   ```bash
   H=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bench-hash.sh" "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md"); echo "$H"
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
   `.beads/issues.jsonl` is created and **committed** (not merely staged — `bd init`
   auto-commits the beads files; verify with `git cat-file -s HEAD:.beads/issues.jsonl`).
3. **Establish the portable rehydrate source on origin.** The whole harness assumes the
   board's Dolt history lives on the git `origin` under `refs/dolt/data` (every cold-start
   rehydrate in `scripts/beads-bootstrap.sh` depends on it). `bd init` does NOT create it,
   and the cloud-push hook is web-only — so a local-only board has **no recovery source**
   unless this step runs. If the repo has an `origin` remote:
   The URL form matters: a **bare `https://` URL is read by bd as a DoltHub (gRPC)
   remote** and fails against GitHub; the `git+` prefix selects git transport, which is
   what a GitHub-hosted `refs/dolt/data` needs.
   ```bash
   ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
   [ -n "$ORIGIN" ] && {
     case "$ORIGIN" in
       git@*:*)   DOLT_URL="git+ssh://${ORIGIN%%:*}/${ORIGIN#*:}" ;;
       https://*) DOLT_URL="git+${ORIGIN%.git}.git" ;;
       *)         DOLT_URL="$ORIGIN" ;;
     esac
     bd dolt remote add origin "$DOLT_URL" 2>/dev/null || true
     bd dolt push 2>&1   # writes refs/dolt/data to origin
   }
   ```
   Check the output, not just the exit code: `bd dolt push` prints `No remote is configured
   — skipping` and **exits 0** when the remote didn't register. (SessionStart's
   `beads-bootstrap` re-registers it in every fresh container, since the remote lives in the
   gitignored engine — but init should confirm the push channel works at least once here.)
   Then confirm it landed: `git ls-remote origin 'refs/dolt/*'` must return a ref. If the
   repo has no origin yet, tell the user the board is **local-only and not yet recoverable**,
   and to re-run `bd dolt push` once an origin exists.
4. **Neutralize JSONL merge conflicts (`.beads/.gitattributes`).** `.beads/*.jsonl`
   (`issues.jsonl`, `interactions.jsonl`) are git-tracked but are one-way DERIVED exports of
   the Dolt board — parallel or ephemeral (cloud-container) sessions each re-export them and
   text-conflict on every commit. Ensure `.beads/.gitattributes` marks them `merge=union` (a
   built-in git strategy — no `.git/config` driver to register, so it works on fresh clones):
   ```bash
   ga=.beads/.gitattributes
   grep -q 'merge=union' "$ga" 2>/dev/null || printf '*.jsonl merge=union\n' >> "$ga"
   ```
   Git then keeps both sides instead of raising conflict markers; the next `bd export` rewrites
   the file clean from the authoritative board. Commit `.beads/.gitattributes`. (The SessionStart
   bootstrap also auto-writes this for existing installs, but init should commit it up front.)
5. Do NOT configure a GitHub sync token here — leave it env-only (the health-check skill
   explains why). Do NOT run `bd github sync`.

## Step 3 — Fix project settings (`.claude/settings.json`)
Two edits to the project's `.claude/settings.json` (create it if absent). Show the user the
diff before saving, and leave unrelated keys untouched.

### 3a — De-dupe hooks
The Bench plugin and the `beads` plugin it depends on both supply SessionStart behavior. If
this project's own `.claude/settings.json` has a hand-rolled `SessionStart` hook running
`bd prime` (or `worktree-reap`, or a beads bootstrap script), it now **double-fires** with the
plugin-provided hooks. **Remove the now-duplicate `bd prime` SessionStart entry** (and any
hand-rolled worktree-reap / beads-bootstrap entries the plugin now provides).

### 3b — Make web/cloud sessions load Bench (`enabledPlugins`)
A local `claude plugin install` writes enablement to **`~/.claude/settings.json`** (user
scope), which **does not travel to Claude Code on the web** — a cloud session is a fresh
container that clones only the repo. So without committed config, a web session has no Bench
plugin: the `planner`/`engineer`/`qa`/`reviewer` **subagent identities never register** (the
orchestrator has nothing to spawn) and the SessionStart hooks never fire (so `bd` isn't even
installed). Web sessions load plugins **only** from the repo's committed `.claude/settings.json`.

Ensure that file declares the marketplace and enables both plugins (merge into any existing
`extraKnownMarketplaces` / `enabledPlugins`; don't clobber other entries):
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
`beads` is enabled alongside `bench` because Bench depends on it for the `bd prime` hooks (the
manifest can't declare that cross-marketplace dependency — see the README note). If the project
installed Bench from a fork or a different marketplace, adjust the `repo` accordingly. This edit
is what makes the harness usable in cloud sessions; it's a no-op for local sessions where the
plugin is already enabled at user scope. Remind the user to **commit** `.claude/settings.json`.

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
prefix, settings changes made (hook de-dupe **and** the `enabledPlugins` web-enablement from
Step 3b), permissions added, and which optional roles were installed.
Remind the user to commit the changes (`CLAUDE.md`, `.beads/`, `.claude/`). If the project
needs a role beyond the built-ins and the two optional templates, point them at
`/bench:new-agent <name>` — custom roles are project-owned and auto-discovered, so they do
not require editing (or re-running) the managed CLAUDE.md block.
