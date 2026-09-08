---
name: init
description: One-time (or refresh) per-project setup for the Bench v2 factory — injects the managed CLAUDE.md orchestrator block, copies the role agents, the bench-orchestrator skill, the factory workflow and the scripts they depend on into the project, creates the GitHub labels from the protocol, and installs a dispatch lane (Action or Routine). Re-run after `claude plugin update bench` to refresh the copies.
argument-hint: "[--with data-eng,design-reviewer] [--dispatch action|routine|none]"
---

# /bench:init — initialize the Bench v2 factory in this project

You are setting up Bench in the current project. A plugin cannot edit a project's
`CLAUDE.md`, write into `.claude/`, or create GitHub labels on its own — that is what this
command does. Work through the steps below, reporting what you changed. Normative spec:
`docs/factory-protocol.md` — follow it exactly if anything below is ambiguous.

Arguments (from `$ARGUMENTS`):
- `--with <roles>` — comma-separated optional roles to install: `data-eng`, `design-reviewer`.
- `--dispatch action|routine|none` — which trigger lane to install (protocol §12). If
  omitted, **ask** the user which lane they want; don't default silently.

Plugin paths are pre-substituted: role agents at `${CLAUDE_PLUGIN_ROOT}/agents/`, optional
agents at `${CLAUDE_PLUGIN_ROOT}/agents-optional/`, the orchestrator skill at
`${CLAUDE_PLUGIN_ROOT}/skills/bench-orchestrator/SKILL.md`, the workflow at
`${CLAUDE_PLUGIN_ROOT}/workflows/factory.js`, the scripts roles and CI depend on at
`${CLAUDE_PLUGIN_ROOT}/scripts/`, dispatch templates at
`${CLAUDE_PLUGIN_ROOT}/templates/factory-dispatch-*.yml`.

## Step 1 — Inject the orchestrator rules into CLAUDE.md (versioned marker block)
Same mechanism as v1, one version bump (`v:2` — GitHub Issues replace the v1 tracker). The block is
delimited so it can be refreshed idempotently on future runs.

1. Compute the template's 8-char content hash via the canonical helper (`/bench:doctor` and
   the drift-check hook use the same one, so all three always agree on the format):
   ```bash
   H=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bench-hash.sh" "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md"); echo "$H"
   ```
2. Build the block: a `<!-- BEGIN BENCH v:2 hash:$H -->` line, then the **verbatim contents**
   of `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md`, then a `<!-- END BENCH -->` line.
3. If `CLAUDE.md` doesn't exist, create it with this block. If it exists **and already has a
   `<!-- BEGIN BENCH ... -->` … `<!-- END BENCH -->` block** — match the begin marker
   anchored at the start of a line, so a doc line that merely *mentions* the marker mid-line
   is never mistaken for the block itself — replace that block in place, preserving
   everything else in the file. Otherwise, append the block at the end.

## Step 2 — Copy the roles, skill, scripts and workflow into the project
Cloud sessions never load marketplace plugins — they only see what's committed in the repo.
So the project-owned copies under `.claude/` are what actually runs there; the plugin copies
are the source of truth `/bench:doctor` diffs against. This applies just as much to the
orchestrator skill and the scripts role prompts and CI shell out to: a role prompt or CI job
that says `scripts/tdd-order-check.sh` means a path inside **this project**, not the plugin —
if it's never copied in, that path doesn't exist wherever the plugin itself isn't loaded
(any cloud session, and any GitHub Actions runner, which never has the plugin at all).

1. `mkdir -p .claude/agents .claude/workflows .claude/skills/bench-orchestrator .claude/scripts`.
2. Copy every `${CLAUDE_PLUGIN_ROOT}/agents/*.md` → `.claude/agents/` (`planner`, `engineer`,
   `qa`, `reviewer`). Overwrite any existing copies of these four — they're plugin-owned; a
   project should never hand-edit them (use `/bench:new-agent` for a custom role instead).
3. For each role named in `--with`, copy `${CLAUDE_PLUGIN_ROOT}/agents-optional/<role>.md` →
   `.claude/agents/<role>.md` **only if it doesn't already exist there** — don't clobber a
   copy the user has already filled in. Tell the user it may still contain `<<FILL: ...>>`
   placeholders to complete before the role is used.
4. Copy `${CLAUDE_PLUGIN_ROOT}/skills/bench-orchestrator/SKILL.md` →
   `.claude/skills/bench-orchestrator/SKILL.md` (overwrite — plugin-owned). The managed
   CLAUDE.md block requires invoking this skill before any dispatch beyond a single-file
   edit; without this copy that instruction is unfollowable in every environment that can't
   load the marketplace plugin.
5. Copy `${CLAUDE_PLUGIN_ROOT}/workflows/factory.js` → `.claude/workflows/factory.js`
   (overwrite — plugin-owned).
6. Copy
   `${CLAUDE_PLUGIN_ROOT}/scripts/{factory-ready.sh,gh-issue-dep.sh,tdd-order-check.sh,human-todos.sh}`
   → `.claude/scripts/` (overwrite — plugin-owned), then `chmod +x` each. The first three are
   the scripts referenced by bare `scripts/…` path elsewhere in the role prompts and the skill
   (planner's dependency edges, the sweep lane, the engineer/reviewer TDD-order check) and by
   the CI job Step 5 installs — all of which now mean `.claude/scripts/…` in this project.
   `human-todos.sh` is the protocol §15 reminder surface; copying it here is necessary but not
   sufficient — Step 2.7 is what actually makes it run.
7. Wire `human-todos.sh` into a SessionStart hook. The plugin's own `hooks/hooks.json` never
   reaches a project (Step 2's preamble above), so without a project-owned hook, §15's "the
   plugin runs it best-effort at SessionStart, so a new session starts with the outstanding asks
   in view" is only true in a local session with the marketplace plugin loaded — silent in every
   cloud session, Routine-lane session, or Actions run, which is exactly where a forgotten
   `human:todo` costs the most. Merge into `.claude/settings.json`; never clobber an existing
   file or its other keys/hooks:
   ```bash
   SETTINGS=.claude/settings.json
   CMD="bash .claude/scripts/human-todos.sh"
   [ -f "$SETTINGS" ] || { mkdir -p .claude; echo '{}' > "$SETTINGS"; }
   if jq -e . "$SETTINGS" >/dev/null 2>&1; then
     jq --arg cmd "$CMD" '
       (.hooks.SessionStart // []) as $ss
       | ($ss | map(.hooks[]?.command) | index($cmd)) as $present
       | if $present == null then
           .hooks.SessionStart = ($ss + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}])
         else . end
     ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
   else
     echo "$SETTINGS is not valid JSON — merge this hook entry by hand:"
     echo '{"type":"command","command":"'"$CMD"'"}'
   fi
   ```
   If `jq` isn't on `PATH`, or `.claude/settings.json` isn't valid JSON, print the hook entry
   above and file a `human:todo` for it in Step 6 instead of leaving it silently unwired.

## Step 3 — Create the labels (protocol §3)
If `gh` is on `PATH`:
```bash
for l in \
  "factory:ready:0E8A16" "factory:in-progress:FBCA04" "factory:approved:0E8A16" \
  "needs-human:B60205" \
  "gate:engineer:1D76DB" "gate:qa:1D76DB" "gate:reviewer:1D76DB" \
  "type:epic:5319E7" "lane:ui:C5DEF5" "lane:data:C5DEF5" \
  "priority:p0:B60205" "priority:p1:D93F0B" "priority:p2:FBCA04" \
  "priority:p3:C2E0C6" "priority:p4:EDEDED" \
  "task:BFD4F2" "chore:BFD4F2" "human:todo:B60205"; do
  name="${l%:*}"; color="${l##*:}"
  gh label create "$name" --color "$color" --force
done
```
Also create `gate:design-reviewer` and/or `gate:data-eng` when the matching role was
installed in Step 2. `gh label create --force` updates the color if the label already exists
and never errors on a duplicate — safe to re-run. GitHub's default `bug` / `enhancement`
labels satisfy the rest of the `type:*` vocabulary; only `task` and `chore` need creating.

If `gh` is not on `PATH`, print the same list (name, color, meaning from §3) and tell the
user to create them by hand or via the repo's Labels settings page — there is no bulk
label-creation GitHub MCP tool to fall back on.

## Step 4 — Install the dispatch lane (`--dispatch`)
Resolve `--dispatch`; if absent, ask which lane the user wants: **action** (runs on a GitHub
Actions runner, token-billed, generally available), **routine** (runs in a Claude Code cloud
session, subscription-billed, research preview), or **none** (skip — dispatch stays manual or
sweep-only).

- `action` → copy `${CLAUDE_PLUGIN_ROOT}/templates/factory-dispatch-action.yml` to
  `.github/workflows/factory-dispatch.yml`. Tell the user it needs one repo secret:
  `ANTHROPIC_API_KEY` (repo Settings → Secrets and variables → Actions → New repository
  secret).
- `routine` → copy `${CLAUDE_PLUGIN_ROOT}/templates/factory-dispatch-routine.yml` to
  `.github/workflows/factory-dispatch.yml`. Tell the user it needs the same
  `ANTHROPIC_API_KEY` secret, **plus** a repo variable `BENCH_ROUTINE_ID` naming a Routine
  created ahead of time (e.g. `create_trigger` with `create_new_session_on_fire: true` and a
  prompt like "Run the factory workflow for the issue named in this message" — its returned
  `trig_...` id is the variable value), and that Routines are a **research preview**: the
  `/fire` endpoint and its `anthropic-beta` header may change.
- `none` → install nothing here. Remind the user that issues still get worked via the sweep
  lane (a cron Routine or Action running `.claude/scripts/factory-ready.sh`) or by dispatching
  the workflow or roles by hand.

If `.github/workflows/factory-dispatch.yml` already exists and differs from the template
being installed, show the diff and ask before overwriting — it may be a deliberate
customization.

## Step 5 — Wire the TDD-order check into CI
`.claude/scripts/tdd-order-check.sh <base>..<head>` (copied into the project in Step 2.6) is
the machine check for protocol §7 (the red test must be its own commit before any production
change). The CI job runs as plain shell on a GitHub Actions runner — there is no Claude Code
session and no `${CLAUDE_PLUGIN_ROOT}` there, so the job can only work against a path that was
actually committed into the repo; that's why Step 2.6 must run before this step, and why the
job below points at `.claude/scripts/`, never a bare `scripts/…`.

1. Look for an existing CI workflow under `.github/workflows/` — anything that isn't the
   dispatch workflow just written (commonly `ci.yml`, `test.yml`, `check.yml`).
2. If one exists, append a job to it and show the diff before saving:
   ```yaml
   tdd-order:
     runs-on: ubuntu-latest
     steps:
       - uses: actions/checkout@v4
         with:
           fetch-depth: 0
       - run: bash .claude/scripts/tdd-order-check.sh "origin/${{ github.base_ref }}..HEAD"
   ```
3. If no CI workflow exists, print that snippet and tell the user where to add it — don't
   invent a whole new CI pipeline just to host this one job.

## Step 6 — File human to-dos for what init could not do
A plugin command can't set a GitHub secret, create a repo variable, or click through
Settings pages itself. Per protocol §15, don't just print instructions and move on — file one
`human:todo` issue (label from Step 3) for **each** outstanding item below that applies to
this run, so the ask survives past this session instead of only living in the terminal
scrollback. Use the §15 body template (`## What I need from you` / `## Steps` / `## When
you're done` / `## Blocks`) with copy-pasteable `Steps`, and assign per the §15 resolution
order in protocol §15 (init's to-dos block no pipeline issue, so its step 2 does not apply).

- **`ANTHROPIC_API_KEY` secret** — if Step 4 installed a dispatch lane (`action` or
  `routine`) and the secret isn't already set (`gh secret list` if reachable):
  ```
  gh secret set ANTHROPIC_API_KEY
  ```
  or Settings → Secrets and variables → Actions → New repository secret
  (`https://github.com/<owner>/<repo>/settings/secrets/actions/new`), name
  `ANTHROPIC_API_KEY`.
- **`BENCH_ROUTINE_ID` variable + the Routine itself** — if Step 4 installed the `routine`
  lane: create the Routine first (`create_trigger` with `create_new_session_on_fire: true`
  and a prompt like "Run the factory workflow for the issue named in this message"), then
  ```
  gh variable set BENCH_ROUTINE_ID --body "<trig_... id from create_trigger>"
  ```
  or Settings → Secrets and variables → Actions → Variables → New repository variable
  (`https://github.com/<owner>/<repo>/settings/variables/actions/new`), name
  `BENCH_ROUTINE_ID`.
- **Labels** — if Step 3 found `gh` absent and only printed the label list: the full
  `gh label create` loop from Step 3 to run once `gh` is available, or the manual path via
  Settings → Labels (`https://github.com/<owner>/<repo>/labels`).
- **TDD-order CI snippet** — if Step 5 found no existing CI workflow to append to: the
  `tdd-order:` job snippet Step 5 printed, and where to add it (a new
  `.github/workflows/ci.yml`, or wherever the project's checks eventually live).
- **`human-todos.sh` SessionStart hook** — if Step 2.7 couldn't merge it (`jq` missing, or
  `.claude/settings.json` isn't valid JSON): the hook entry Step 2.7 printed, and where it
  goes (`.claude/settings.json`'s `hooks.SessionStart`) — without it, §15's reminder surface
  never runs in this project.

Skip any item that doesn't apply this run (e.g. `--dispatch none`, or the secret/variable
already exists). File nothing here if every item was already satisfied.

## Step 7 — Report
Summarize: the CLAUDE.md block (added or refreshed, with the version + hash), which agents,
the `bench-orchestrator` skill, the workflow and the four scripts were copied or overwritten,
whether the `human-todos.sh` SessionStart hook was merged into `.claude/settings.json` or only
printed, which optional roles were installed, the labels created (or the printed list if `gh`
was unavailable), the dispatch lane installed or skipped and the secrets/variables it still
needs, and whether the TDD-order CI job was added or only printed. List every `human:todo` issue
filed in Step 6, with its URL and what it covers. Remind the user to commit `CLAUDE.md`,
`.claude/`, and `.github/workflows/`. Point them at `/bench:doctor` to verify the install, and
at `/bench:new-agent <name>` for any role beyond the built-ins and the two optional templates.
