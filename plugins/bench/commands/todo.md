---
name: todo
description: File a `human:todo` GitHub issue from the current session in one step — the §15 mechanism for handing the human a substantial action or decision without losing it to the chat transcript. Use for anything that leaves the conversation, outlives the session, or blocks pipeline work; skip it for a quick yes/no you'll get answered in the next message.
argument-hint: "\"<what you need from the human>\" [--blocks <issue-number>]"
---

# /bench:todo — file a human to-do

You are filing one `human:todo` issue per docs/factory-protocol.md §15. Normative spec: that
document — follow it exactly if anything below is ambiguous.

Arguments (from `$ARGUMENTS`):
- **`"<what>"`** (required) — plain-English description of what the human needs to do or
  decide, and why.
- `--blocks <n>` — a pipeline issue that cannot proceed until this to-do is closed.

**GitHub access.** Same rule as every role (protocol §2): if `gh` is on `PATH`, use it
(`gh issue create`, `gh issue edit`, `gh api user`); otherwise use the GitHub MCP tools
(`issue_write`, `issue_read`, `get_me`). Load them with ToolSearch if not already in context.

## Step 1 — Turn `<what>` into the §15 body

Fill the verbatim template from the argument:

```markdown
## What I need from you
<one paragraph, plain English, no jargon — what and why>

## Steps
1. <exact command, script, or click path — copy-pasteable>
2. <…>

## When you're done
<how the factory notices — usually "close this issue">

## Blocks
- #<n>   (only with --blocks; omit the section otherwise)
```

The bar is that a `Steps` entry must be something the human can copy and run or a settings
page they can navigate to directly — not a restatement of the ask. If `<what>` doesn't give
you enough to make the `Steps` copy-pasteable, ask **one** clarifying question before filing;
otherwise file it without asking — that's the point of a one-step command.

## Step 2 — Resolve the assignee (§15 order)

1. `gh api user --jq .login`, or the `get_me` MCP tool if `gh` is unavailable.
2. If that fails (e.g. a bot token), the author of the pipeline issue named by `--blocks`, or
   of its parent epic.
3. Otherwise the repository owner.

## Step 3 — File the issue

```bash
gh issue create --title "<imperative, human-facing title>" --body-file <f> \
  --label human:todo --assignee <login>
```

(MCP path: `issue_write` to create, with `labels: ["human:todo"]` and `assignees: [<login>]` —
the §2 replace-whole-set warning is about editing an *existing* issue's labels, not creating a
new one, so it doesn't apply here.)

## Step 4 — Wire `--blocks`, if given

Read pipeline issue `#n`'s current body, add `- #<todo>` under its `## Blocked by` section
(create the section if absent), and write the body back. Where the GitHub dependency API is
reachable, also set a native `blocked by` edge (`scripts/gh-issue-dep.sh block <n> <todo>` if
present in this project, else `gh api` directly). Don't label `#n` `needs-human` — that label
is reserved for a gate escalation (§8); dropping out of §5 readiness is the unblock here.

## Step 5 — Report

Print the new issue's URL, its assignee, and — if `--blocks` was given — confirmation that
`#n`'s `## Blocked by` now cites it.
