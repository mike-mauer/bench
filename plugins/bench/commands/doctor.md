---
name: doctor
description: Read-only health check of the Bench v2 install in this project — verifies GitHub reachability, that the project's role/workflow copies match the plugin, that the labels and dispatch lane are installed, that the CLAUDE.md block is current, and that TDD order is enforced in CI. Does not modify anything.
---

# /bench:doctor — verify the Bench v2 install

Run a **read-only** diagnostic of the Bench install in the current project and print one
table: `Check | Status | Fix`, where Status is `PASS` / `WARN` / `FAIL`. Do not modify any
files. Normative spec: `docs/factory-protocol.md`.

1. **GitHub reachability.** If `gh` is on `PATH`, run `gh auth status`. Otherwise confirm the
   GitHub MCP tools are reachable — `ToolSearch` for `get_me`/`issue_read` if not already in
   context, then call `get_me`. Neither reachable → **FAIL** ("no Worker can read or post to
   an issue"). Fix: `gh auth login`, or connect the GitHub MCP server.
2. **Built-in role files present and current.** For each of `planner`, `engineer`, `qa`,
   `reviewer`: check `.claude/agents/<role>.md` exists and is byte-identical to
   `${CLAUDE_PLUGIN_ROOT}/agents/<role>.md` (`diff -q`, or compare `bench-hash.sh` output on
   both). Missing → **FAIL** (`/bench:init` copies them). Differs → **WARN**, "drifted from
   the plugin copy" — a project should never hand-edit a built-in role; re-run `/bench:init`
   to refresh, or rename it into a custom role if the difference is intentional.
3. **Optional roles.** Same byte comparison against `${CLAUDE_PLUGIN_ROOT}/agents-optional/`
   for any of `data-eng` / `design-reviewer` present in `.claude/agents/`. Report each as
   installed-current, installed-drifted, or not installed (not installed is **PASS** — these
   are opt-in, not required).
4. **Custom roles.** List every other `.claude/agents/*.md`. For each, **WARN** if it still
   has any unresolved `<<FILL: ...>>` placeholder in its `## Routing` block (`Spawn when`,
   `Sits`, `On pass → NEXT`, `On fail → NEXT`) — the orchestrator can't place a role it can't
   route.
5. **Workflow file present and current.** `.claude/workflows/factory.js` exists and is
   byte-identical to `${CLAUDE_PLUGIN_ROOT}/workflows/factory.js`. Missing → **FAIL**. Differs
   → **WARN**. Fix either way: `/bench:init`.
6. **Labels exist** (protocol §3). `gh label list --limit 200` (or the GitHub MCP
   equivalent). Check for: `factory:ready`, `factory:in-progress`, `factory:approved`,
   `needs-human`, `gate:engineer`, `gate:qa`, `gate:reviewer`, plus `gate:<role>` for every
   optional/custom role found in checks 3–4, `type:epic`, `lane:ui`, `lane:data`,
   `priority:p0`…`priority:p4`, `task`, `chore`, `human:todo`. Any missing → **WARN**, list
   which. Fix: `/bench:init` (Step 3).
7. **CLAUDE.md block current.** Reuse the drift-check hook's exact logic:
   ```bash
   WANT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/bench-hash.sh" "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md")
   HAVE=$(grep -o '^<!-- BEGIN BENCH[^>]*hash:[0-9a-f]*' CLAUDE.md 2>/dev/null | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)
   echo "want=$WANT have=$HAVE"
   ```
   Absent → **FAIL**. Present but `have != want` → **WARN**, "stale". Fix: `/bench:init`
   (Step 1).
8. **Dispatch lane.** Check `.github/workflows/factory-dispatch.yml`. If present, report
   which template it matches (diff against both
   `${CLAUDE_PLUGIN_ROOT}/templates/factory-dispatch-action.yml` and
   `...-routine.yml`) and name the secret/variable it references (`ANTHROPIC_API_KEY`, plus
   `BENCH_ROUTINE_ID` for the routine lane). This command can't read secret *values*, only
   whether the workflow references them — say so, and **WARN** if a needed secret or
   variable can't be confirmed to exist (`gh secret list` / `gh variable list`). Absent →
   **WARN**, "no dispatch lane installed — issues won't auto-dispatch on labeling." Fix:
   `/bench:init` (Step 4) — or note it may be intentional if the project relies only on the
   sweep lane or manual dispatch.
9. **TDD-order check in CI.** Search `.github/workflows/*.yml` for a step invoking
   `scripts/tdd-order-check.sh`. Absent → **WARN**, "TDD commit order isn't enforced in CI."
   Fix: `/bench:init` (Step 5), or add the snippet by hand.
10. **Open `human:todo` issues for you** (protocol §15). Resolve the current user the same way
    `/bench:todo` does (`gh api user --jq .login`, else `get_me`), then `gh issue list --label
    human:todo --assignee @me --state open --json number,title,createdAt` (or the equivalent
    MCP search/list). List the count and every `#<n> <title>` in the row regardless of status.
    None → **PASS**, "0 open". Any open, all ≤14 days old → **PASS**. Any open ≥14 days old →
    **WARN**, note which ones and their age. This is a report, not an install defect, so
    there's nothing to "fix" beyond doing or delegating the to-dos themselves — the Fix column
    reads "—".

End with a one-line summary (counts of PASS/WARN/FAIL) and, for every non-PASS row, the exact
fix command already shown in its row — don't make the user hunt back through the table.
