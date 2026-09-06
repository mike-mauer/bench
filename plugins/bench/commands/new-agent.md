---
name: new-agent
description: Scaffold a custom Bench role agent into this project's .claude/agents/. Generates a Bench-compliant Worker (handoff comment format, GitHub-issue context, self-declared pipeline routing) from a generic template, so the orchestrator can discover and route to it without editing the managed CLAUDE.md block. Use when the built-in roles (engineer/qa/reviewer) and the optional data-eng/design-reviewer don't cover a concern you want gated.
argument-hint: "<name> [--kind builder|gate] [--model haiku|sonnet|opus] [--tools 'Read, Bash, ...'] [--sits '<where in pipeline>']"
---

# /bench:new-agent — scaffold a custom pipeline role

You are creating a new **custom role agent** for this project's Bench pipeline. Unlike the
built-in roles (which ship in the plugin) and the two optional templates (`data-eng`,
`design-reviewer`, installed via `/bench:init --with`), a custom role is **project-owned**: it
lives in `.claude/agents/<name>.md`, which `/bench:init` never touches, so it survives plugin
refreshes. The orchestrator — the `factory` workflow or the main session dispatching by hand —
discovers it by listing `.claude/agents/` and reading its frontmatter `description` plus
`## Routing` block. There is **nothing to add to the managed `<!-- BEGIN BENCH -->` CLAUDE.md
block**, and you must not add anything there — it is regenerated on refresh; the agent file
itself is the durable registration.

The generic template is at `${CLAUDE_PLUGIN_ROOT}/templates/custom-agent.md`.

Arguments (from `$ARGUMENTS`):
- **`<name>`** (required) — the role name. Lowercase, hyphenated, no spaces — used verbatim
  as the agent `name`, in `NEXT:`/`FYI:` routing tags, and as the `## Handoff from <name>`
  comment heading it posts on issues. Examples: `api-reviewer`, `quality`, `perf`, `docs`.
- `--kind builder|gate` — `builder` writes code and opens a PR (TDD loop); `gate` reviews or
  verifies and writes no code. Default `gate` (the common case for a new role).
- `--model haiku|sonnet|opus` — frontmatter default model. Default `sonnet`.
- `--tools '<list>'` — frontmatter `tools:` line. Default for `gate`: `Read, Bash, Grep, Glob`
  (no write access); for `builder`: `Read, Edit, Write, Bash, Grep, Glob`.
- `--sits '<text>'` — free-text pipeline position for the `## Routing` block, e.g.
  `'after qa, before reviewer'`. If omitted, leave the `<<FILL>>` for the user.

## Step 1 — Validate
1. Require a `<name>`. Reject names with spaces/uppercase/slashes, and reject the reserved
   built-in/optional names: `planner`, `engineer`, `qa`, `reviewer`, `data-eng`,
   `design-reviewer`, `orchestrator`. If `.claude/agents/<name>.md` already exists, **stop and
   ask** before overwriting — don't clobber a role the user has already filled in.
2. Resolve the substitution values from the flags + kind defaults:
   - `{{NAME}}` → the name.
   - `{{KIND}}` → `builder` or `gate`.
   - `{{MODEL}}` → the model (default `sonnet`).
   - `{{TOOLS}}` → the tools list (kind default if `--tools` absent).
   - `{{NEEDS_WORKTREE}}` → `yes` for a `builder`, else `no` (a gate that runs or inspects the
     app also needs `yes`). This matters in both dispatch paths, not just interactive
     hand-dispatch: `.claude/workflows/factory.js` passes `isolation: 'worktree'` on every
     builder and gate `agent()` call, because wave-level fan-out can run several issues'
     Workers concurrently in that one script, and each needs its own checkout so they don't
     race on a shared working tree. A role that answers `yes` here needs that same isolation
     wherever it's dispatched from.
   - `{{POSITION}}` → the `--sits` text, else `<<FILL: where this role sits in the pipeline>>`.
   - `{{NEXT_PASS}}` / `{{NEXT_FAIL}}` → `<<FILL: ...>>` (the user wires these to real roles).

## Step 2 — Generate the agent file
1. Ensure `.claude/agents/` exists (`mkdir -p`).
2. Read `${CLAUDE_PLUGIN_ROOT}/templates/custom-agent.md`, replace every `{{TOKEN}}` with the
   resolved values from Step 1 (leave the `<<FILL: ...>>` human placeholders intact), and
   write the result to `.claude/agents/<name>.md`.
3. Do **not** remove the `<<FILL: ...>>` placeholders — they mark what the user must complete
   before the role is ready to route.

## Step 3 — Create its gate label
If `gh` is on `PATH`, offer to run `gh label create "gate:<name>" --color 1D76DB --force` so
the role's gate label exists before its first handoff tries to add it — `gh issue edit
--add-label` fails on a label that doesn't already exist. `/bench:doctor` also checks for it
and will flag it missing if this step is skipped.

## Step 4 — Tell the user what's left
1. Show the path written and the resolved frontmatter.
2. List the `<<FILL: ...>>` placeholders that remain (role description, what-you-own, the
   step-by-step checklist, reading list, and any unresolved `## Routing` fields). Offer to
   fill them now interactively.
3. Remind them: the role is **live as a spawnable subagent once committed** — the orchestrator
   discovers it from `.claude/agents/` and routes per its `description` and `## Routing`. No
   `/bench:init` re-run is needed for a custom role — it is not part of the managed block.
4. Remind them to commit `.claude/agents/<name>.md`.

## Step 5 — Report
Summarize: the file created, its kind/model/tools, whether routing is fully specified or
still has `<<FILL>>`s, whether the gate label was created, and the next action (fill
placeholders → commit). Point them at `/bench:doctor`, which lists custom roles and flags any
left with placeholders or a missing gate label.
