---
name: new-agent
description: Scaffold a custom Bench role agent into this project's .claude/agents/. Generates a Bench-compliant Worker (handoff block, --actor attribution, direct bd access, self-declared pipeline routing) from a generic template, so the orchestrator can discover and route to it without editing the managed CLAUDE.md block. Use when the built-in roles (engineer/qa/reviewer) and the optional data-eng/design-reviewer don't cover a concern you want gated.
argument-hint: "<name> [--kind builder|gate] [--model haiku|sonnet|opus] [--tools 'Read, Bash, ...'] [--sits '<where in pipeline>']"
---

# /bench:new-agent — scaffold a custom pipeline role

You are creating a new **custom role agent** for this project's Bench pipeline. Unlike
the built-in roles (which ship in the plugin) and the two optional templates (`data-eng`,
`design-reviewer`, installed via `/bench:init --with`), a custom role is **project-owned**:
it lives in `.claude/agents/<name>.md`, which `/bench:init` never touches — so it survives
plugin refreshes. The orchestrator discovers it by listing `.claude/agents/` and reading
its frontmatter `description` + `## Routing` block; there is **nothing to add to the managed
`<!-- BEGIN BENCH -->` CLAUDE.md block** (and you must not — it is regenerated on refresh).

The generic template is at `${CLAUDE_PLUGIN_ROOT}/templates/custom-agent.md`.

Arguments (from `$ARGUMENTS`):
- **`<name>`** (required) — the role / actor name. Lowercase, hyphenated, no spaces (it is
  used verbatim as the agent `name`, the board `--actor`, and the `NEXT:`/`FYI:` routing
  tags). Examples: `api-reviewer`, `quality`, `perf`, `docs`.
- `--kind builder|gate` — `builder` writes code (gets a worktree, TDD loop); `gate` reviews
  or verifies and writes no code. Default `gate` (the common case for a new role).
- `--model haiku|sonnet|opus` — frontmatter default model. Default `sonnet`.
- `--tools '<list>'` — frontmatter `tools:` line. Default for `gate`: `Read, Bash, Grep, Glob`
  (no write access); for `builder`: `Read, Edit, Write, Bash, Grep, Glob`.
- `--sits '<text>'` — free-text pipeline position for the `## Routing` block, e.g.
  `'after qa, before reviewer'`. If omitted, leave the `<<FILL>>` for the user.

## Step 1 — Validate
1. Require a `<name>`. Reject names with spaces/uppercase/slashes, and reject the reserved
   built-in/optional names: `planner`, `engineer`, `qa`, `reviewer`, `data-eng`,
   `design-reviewer`, `orchestrator`. If `.claude/agents/<name>.md` already exists, **stop and
   ask** before overwriting (don't clobber a filled-in role).
2. Resolve the substitution values from the flags + kind defaults:
   - `{{NAME}}` → the name.
   - `{{KIND}}` → `builder` or `gate`.
   - `{{MODEL}}` → the model (default `sonnet`).
   - `{{TOOLS}}` → the tools list (kind default if `--tools` absent).
   - `{{NEEDS_WORKTREE}}` → `yes` for `builder`, else `no` (a gate that runs/inspects the
     app also needs `yes` — note this to the user).
   - `{{POSITION}}` → `--sits` text, else `<<FILL: where this role sits in the pipeline>>`.
   - `{{NEXT_PASS}}` / `{{NEXT_FAIL}}` → `<<FILL: ...>>` (the user wires these to real roles).

## Step 2 — Generate the agent file
1. Ensure `.claude/agents/` exists (`mkdir -p`).
2. Read `${CLAUDE_PLUGIN_ROOT}/templates/custom-agent.md`, replace every `{{TOKEN}}` with the
   resolved values from Step 1 (leave the `<<FILL: ...>>` human placeholders intact), and
   write the result to `.claude/agents/<name>.md`.
3. Do **not** remove the `<<FILL: ...>>` placeholders — they mark what the user must complete.

## Step 3 — Tell the user what's left
1. Show the path written and the resolved frontmatter.
2. List the `<<FILL: ...>>` placeholders that remain (role description, what-you-own, the
   Workflow checklist/TDD steps, reading list, and any unresolved `## Routing` fields). Offer
   to fill them now interactively.
3. Remind them: the role is **live as a spawnable subagent once committed** — the orchestrator
   will discover it from `.claude/agents/` and route per its `description` + `## Routing`. No
   `/bench:init` re-run is needed for a custom role (it is not part of the managed block).
4. Remind them to commit `.claude/agents/<name>.md`.

## Step 4 — Report
Summarize: the file created, kind/model/tools, whether routing is fully specified or still
has `<<FILL>>`s, and the next action (fill placeholders → commit). Point them at
`/bench:doctor`, which now lists custom roles and flags any left with placeholders.
