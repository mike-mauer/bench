---
name: beads-health-check
description: >-
  Run a full-system health + safe-repair pass — the "oil" that keeps a beads-backed
  project smooth and clean across five domains: beads (the bd issue tracker),
  GitHub sync-safety, git repo hygiene, dependencies, and CI/cron. Catches failure
  modes teams actually hit (bd version drift, GitHub-sync duplicates & pull-create
  risk, export drift, orphaned dependencies, polluted git working tree, lockfile
  drift, missing crons, CI failures). Use whenever the user asks to "check beads
  health", "system health check", "is everything ok / in sync", "clean up the
  board", "beads doctor", "repair beads", or after any session where bd or the repo
  behaved unexpectedly (panics, dup issues, sync errors, detached HEAD). Read-only
  on the app: it observes CI/deploy/cron/dep state to report, but NEVER modifies app
  code, runs app tests/builds, triggers deploys, or runs bd github sync.
---

# System Health Check + Repair (Bench harness)

The **"oil"** that keeps a beads-backed project running smooth, up to date, and
clean. This is a **maintenance** skill, not a feature skill — its whole job is
hygiene, across five domains: **beads** (the `bd` tracker), **github** (sync-safety),
**git** (repo hygiene), **deps** (dependencies), and **ci** (CI/cron). Run it
**especially after** a board rebuild (`bd init` + `bd import`), a version change, a
`bd github` operation, a dependency bump, or any session where bd or the repo
behaved oddly — those are exactly when parent edges, dups, sync-safety, and
integrity quietly break.

The beads structural side (epics, parents, duplicates, orphans) is usually where
most real cleanup time goes, so it's the deepest domain.

## Prime directive: observe everything, act only on provably-safe internal hygiene
You tend the system's plumbing, not the product. One rule everything follows:
> **Observe broadly (read-only across all five domains); act only on provably-safe
> internal hygiene. Never perform an outward-facing or production-affecting action
> automatically — flag it with the exact command to run by hand.**

Concretely:
- **You MAY read** beads, GitHub, git, dependency, and CI/cron state to report on it.
- **You must NEVER** modify application code, run app tests/builds, trigger deploys,
  run `bd github sync`/push/pull, auto-close GitHub issues, or auto-bump dependencies.
- **The only things you ever change** are provably-safe internal hygiene: `bd dolt pull`,
  regenerating `.beads/issues.jsonl`, and reaping merged/stale agent worktrees.
  Everything else is flagged for a human with the exact command.

If a finding points at app code, CI failures, or a needed deploy, **note it and stop** —
reporting is in scope, fixing the app is not.

## The two buckets
Every finding sorts into exactly one. The skill hinges on getting the sort right.
- **Safe to auto-fix** — provably reversible or purely additive hygiene that keeps
  the board consistent with itself and the remote. Do these without asking.
- **Flag for human** — anything destructive, anything outward-facing that could
  propagate a bad state, anything involving the binary version, and anything
  GitHub-sync related. Report it with the exact command and *why*. When in doubt,
  a finding belongs here.

## Workflow
Work top to bottom. Read-only diagnostics first; only act once you've classified.

> **If the board runs embedded Dolt** (`bd info` → `Mode: direct`; `bd dolt show` →
> `embedded`), note that **`bd doctor` is NOT supported in embedded mode** — the
> checks below are the embedded-mode equivalents. In server mode, `bd doctor`
> becomes available and is worth adding back.

### 1. Snapshot (read-only)
```bash
bd version                # compare against the project's pinned version (see §version drift)
bd info                   # mode + issue count
bd status                 # board overview / open-closed counts
git status                # working-tree state (READ ONLY — never checkout/stash/reset here)
git stash list            # stray stashes are a known damage signature (see §Git integrity)
```

### 2. Diagnostics (read-only) — none of these mutate state
```bash
# --- board structure / cleanliness (the bulk of what breaks) ---
bd list --type=epic                  # enumerate epics
bd show <prefix-epicId>              # per epic: CHILDREN section + "N/M complete" (use the FULL id)
bd lint                              # issues missing required template sections
bd stale                             # issues with no recent activity
bd orphans                           # issues with broken/absent dependency references
bd duplicates                        # in-beads semantic duplicates
# --- sync / engine ---
bd dolt show                         # engine mode + remote config
git for-each-ref | grep refs/dolt    # local dolt data ref
git ls-remote origin 'refs/dolt/*'   # remote dolt data ref (sync state)
cat .beads/export-state.json         # last export commit + issue count
bd github status                     # bridge config — DIAGNOSTIC ONLY
```
Sync state is read by comparing the **local `refs/dolt/data`** to the **remote
`refs/dolt/data`**, and by checking the `issues` count in `.beads/export-state.json`
against `bd status`.

### 3. Classify and act

#### Version drift — ALWAYS flag, never auto-fix
Check `bd version` against the project's pin (the Bench plugin installs the version
set by its `bd_version` config, default `1.0.4`). Anything else is the finding — flag
it loudly. **Never run `bd upgrade`** as an auto-fix; version changes are a human
decision. (Context: beads `1.0.5` reintroduced a panic on bulk reads with large TEXT
rows — upstream #4267/#4049 — which is why `1.0.4` is the conservative default pin.)

#### GitHub-sync duplicates — ALWAYS flag, never run `bd github sync`
The most expensive footgun. `bd github sync` matches issues across the beads↔GitHub
boundary by `external_ref` **only** — not by title. When the same work exists on both
sides without a cross-link, sync *creates duplicates on both sides* and recompounds
every run. Dry-run does **not** simulate pull-creates, so a clean dry-run is NOT safe.
This skill **never** runs `bd github sync`/push/pull.

If the GitHub token is kept **env-only** (not persisted to config) so nothing
auto-fires sync, `bd github status` reporting **"Not configured"** is the *desired*
state — do NOT flag it as a defect or set a token to "fix" it.

Detection is split (you can't query the GitHub side through `bd` without a token):
- **In-beads side**: `bd duplicates` (semantic) plus a scan for issues that look like
  they correspond to a GitHub issue but lack an `external_ref` cross-link — that
  missing link is the dup mechanism.
- **GitHub side**: check via `gh` (`gh issue list -R <owner>/<repo>`) or the UI — not
  via `bd`. Report same-title open issues and any known unreconciled clusters.

Repair is always human-driven (manual cross-link via `external_ref`, or delete the
duplicate). Spell out candidates; never act.

#### Board structure & cleanliness — the part that actually breaks
**Epic parent-edge integrity (the marquee check).** Progress bars and `bd show`
completion counts read **only explicit `parent-child` edges**. A dotted ID alone
(`epic.1`) does **not** register as a child. A board rebuild (`bd init` + `bd import`)
can drop explicit parent edges, leaving epics showing **0/0 despite having children**.

To check: enumerate epics, then `bd show <prefix-epicId>` for each and read the
completion line. The corruption signature is an epic with **no `CHILDREN` section /
`0/0 complete`** when you have reason to believe it has children. Flag for human with
the precise repair:
```
bd update <child> --parent <prefix-epic>     # the correct fix
# NOT: bd dep add <child> <epic>  → rejected for dotted children, silently leaves count at 0
```
Re-parenting is a judgment call, so it's always flag-for-human even though the symptom
is mechanical. Spell out the suspected child→epic mapping; let the human confirm.

**Closure consistency — scan by ID convention, NOT by edges.** Flag epics closed while
children remain open, and open epics whose children are all closed (candidate to close).
Report specific ids; closing is the human's call.

> **Do not derive children from `parent-child` edges here.** Those edges are exactly
> what a board rebuild drops (see the parent-edge check above), so an edge-based scan
> goes **blind to the orphans that matter** — it cheerfully reports "no closed epics
> with open children" while a closed epic still has an `in_progress` child hanging off
> it (observed: a closed epic whose sole dotted child sat `in_progress`, missed because
> its edge was gone). Instead, group by the **dotted-ID convention** — `epic.N` is a
> child of `epic` regardless of whether an edge exists — and scan **every status, not
> just open**: `bd list` defaults to open-only, so a *closed* epic never even appears
> in the dump. Enumerate the full board (`bd list --status all --json`, and confirm it
> wasn't truncated against `bd stats`), bucket issues by their `epic` prefix, and for
> each bucket whose epic is `closed` flag any child not also `closed`. This catches the
> orphans the edge-based progress bars cannot.

#### Sync / export state
- **`bd dolt pull`** when the remote ref is ahead — *safe auto-fix* (can't propagate
  local pollution).
- **Export drift** — *safe auto-fix*. The `issues` count in `.beads/export-state.json`
  should track `bd status`; `.beads/issues.jsonl` is a passive export. If diverged,
  regenerate with `bd export -o .beads/issues.jsonl`. (Small flux between back-to-back
  commands is normal; only act on a real, persistent gap.)
- **`bd dolt push`** — *safe, but gated*. Only push after this run confirmed a clean
  board (no unresolved dups, no integrity flags). If the report isn't clean, flag the
  pending push instead of running it.
- **`.beads/.cloud-push-failed` marker present** — *flag prominently*. The SessionEnd
  cloud-push (web sessions) drops this breadcrumb when it could not get local bead
  writes to the remote after retries — meaning the local board is **ahead of the remote
  and at risk of reverting** on the next cold-container rehydrate. Surface it, run the
  recovery push it names (`BD_SYNC_REMOTE="git+<origin>" bd dolt push`), and once the
  remote has advanced, remove the marker.
- **Committing `.beads/` changes**: stage **path-scoped** — `git add .beads/` — *never*
  `git add -A`/`git add .`. Sweeping in foreign untracked content is how a tree gets
  polluted.

#### Backups / artifacts
- **`.beads/backup/` growth** — *flag for human*, never auto-prune. Report count/size.
- **Stray/legacy artifacts** (loose `*.db`, old `*.jsonl`) — *report*; deletion is the
  human's call.

#### Orphans, stale, lint — flag with specifics
- **Orphans** (broken dep references): *flag* with the exact `bd dep`/`bd update` fix.
- **Stale** issues: *report* the list; don't auto-close.
- **Lint** (missing template sections): *report* which issues and sections. A bead missing its
  spec sections (`## Acceptance criteria`, `## Out of scope`, `## Notes for the builder`) fails the
  **self-sufficiency bar** — a Worker shouldn't need the dispatch prompt to explain scope or rules
  (see `planner` decomposition rule 9). Flag these as underspecified so they're enriched on the bead
  before dispatch, not patched in a one-shot prompt the downstream gates never see.

#### Destructive maintenance — ALWAYS flag
`bd prune`, `bd purge`, `bd gc`, `bd compact`, `bd flatten`, `bd delete`,
`rename-prefix` — all delete or rewrite history. Never run as auto-fixes; recommend
with rationale and let the human run it.

#### GitHub sync-safety (domain: github) — all flag-for-human
- **sync preflight** — open GH issues with **no matching bead `external_ref`**. Each
  would be **created** as a bead on a real pull. This is the trustworthy "0
  pull-creates" gate — a `--dry-run --pull-only` is *blind* to pull-creates. Reconcile
  each (cross-link or close) before any sync is considered.
- **test artifacts** — open probe/test issues → flag to close on GitHub; don't pull.
- **orphan refs** — beads whose `external_ref` points at a missing GH issue.
- **github dups** — same-title open issues + known clusters.

Re-enabling sync is a human step gated on the preflight being clean — not on the dry-run.

#### Git repo hygiene (domain: git)
- **branch sync** — ahead/behind upstream (`@{u}`, no fetch); detached HEAD is
  attention. *Report* — pushing/pulling is the human's call (beyond the `.beads/` path).
- **foreign untracked** — stray files (e.g. `.claude/skills/`, lockfiles) → **flag**,
  never `git add -A`, never auto-clean.
- **orphaned worktrees** — leftover `.claude/worktrees/` trees. Reaping merged/stale
  trees is the **one git safe-fix** (it only force-removes merged/stale trees).

#### Dependencies (domain: deps) — read-only, NEVER auto-bump
- **lockfile drift** — lockfile vs manifest. The fix (install + commit lockfile) is a
  **human action** — flag it, don't run it.
- **audit** — advisories from the package manager's audit. *Report* counts; never
  auto-upgrade.

#### CI / cron (domain: ci) — read-only, NEVER triggers deploys
- **cron config** — the project's documented scheduled jobs must be present in config;
  flag drift.
- **recent runs** — recent CI failures on the integration branch(es). *Report* —
  fixing CI is app work, out of scope.

### 4. Git integrity around `.beads`
Beads syncs through git, so a damaged working tree breaks beads. Watch for: detached
HEAD, unexpected branch, dirty tree with foreign untracked content, recovery/leftover
stashes. If you see any, **flag them** — do not `checkout`/`stash`/`pop`/`reset` to
"fix" it. Blind recovery is what causes cascades. Describe what you see; let the human
untangle it.

### 5. Report
```
# Beads Health Report — <date>

## Summary
<one line: healthy / N safe fixes applied / M items need you>

## Auto-fixed (safe)
- <what changed>

## Needs your decision
- [version] <only if bd version ≠ the project pin>
- [structure] <epics with 0/0 or dropped parent edges → suggested --parent fixes; closure mismatches>
- [github-dups] <clusters, with external_ref status; reminder: do not run bd github sync>
- [orphans] <issue → exact fix>
- [destructive] <recommended command + why>
- [git] <integrity signatures, if any>

## Clean
<checks that passed, so coverage is visible>

## Sync status at end
<dolt push state: pushed / gated pending clean board / nothing to push>
```

## Hard rules (the short list)
1. Never run `bd github sync` / `push` / `pull`.
2. Never run `bd upgrade`; stay on the project's pinned bd version unless a human bumps it.
3. Never run destructive maintenance (`prune`/`purge`/`gc`/`compact`/`flatten`/`delete`)
   as an auto-fix — recommend only.
4. Git is read-only except `git add .beads/` + commit/push of beads sync, and reaping
   merged/stale worktrees. Never `checkout`/`stash`/`pop`/`reset`. Never `git add -A`.
5. `bd dolt push` only after the report is clean.
6. Never touch the application — no app code, tests, builds, or deploys.
7. Never auto-close GitHub issues — flag them with the exact `gh issue close` command.
8. Never auto-bump dependencies — report-only.
9. The trustworthy sync-safety gate is the pull-create preflight (0 unmatched open
   issues), NOT `bd github sync --dry-run` (blind to pull-creates).
