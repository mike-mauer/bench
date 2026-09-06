export const meta = {
  name: 'factory',
  description: 'Run one GitHub issue through the Bench factory: triage, optional planning, build, gates, escalation.',
  whenToUse: 'Unattended dispatch of a factory:ready GitHub issue. args: { issue: <number>, repo?: "owner/name", maxRounds?: 2 }',
  phases: [
    { title: 'Triage', detail: 'read the issue, decide readiness, lane, risk', model: 'haiku' },
    { title: 'Plan', detail: 'epics only: file dependency-ordered sub-issues', model: 'opus' },
    { title: 'Build', detail: 'red test commit, implementation, draft PR' },
    { title: 'QA', detail: 'adversarial verification gates' },
    { title: 'Review', detail: 'TDD-from-history and security review', model: 'opus' },
    { title: 'Escalate', detail: 'bounce cap or blocked: label needs-human and hand back', model: 'haiku' },
  ],
}

// ---------------------------------------------------------------- parameters

const ISSUE = args && args.issue
const REPO = (args && args.repo) || 'the current repository'
const MAX_ROUNDS = (args && args.maxRounds) || 2

const BUILT_IN_GATES = ['qa', 'design-reviewer', 'reviewer']
const BUILT_IN_ROLES = ['planner', 'engineer', 'data-eng', 'qa', 'design-reviewer', 'reviewer']
// The built-in anchors a custom gate's `## Routing` "Sits" field can name — kept as a
// closed enum so triage (an agent) resolves the free-text "after qa, before reviewer" prose
// into something this plain-JS script can splice without parsing English itself.
const CUSTOM_ROLE_ANCHORS = ['start', 'engineer', 'data-eng', 'qa', 'design-reviewer', 'reviewer']

// The issue is the context; role prompts carry the detail. This is the one
// paragraph every call needs so the agent knows which surface to reach GitHub by.
const GH =
  `Repo: ${REPO}. If \`gh\` is on PATH use it; otherwise use the GitHub MCP issue tools ` +
  `(issue_read, add_issue_comment, issue_write, sub_issue_write, create_pull_request, ` +
  `update_pull_request, get_me — load them with ToolSearch first). Read the issue and its ` +
  `comments before acting — the issue is the context, nothing was re-pasted into this prompt.\n\n` +
  `Labels via MCP are replace-whole-set, not add/remove. issue_write's labels field is the ` +
  `GitHub update-issue endpoint's full replacement array — unlike \`gh issue edit ` +
  `--add-label/--remove-label\`, sending it is not additive. On the MCP path: issue_read the ` +
  `issue immediately before every label change, take its current label list, remove/add the ` +
  `label(s) you mean to change, and send the complete resulting array. Never call issue_write ` +
  `with just the label you're adding — that replaces the whole set and silently drops ` +
  `everything else (factory:ready, lane:*, priority:*, type:*, other gate:*).`

// ------------------------------------------------------------------- schemas

const TRIAGE_SCHEMA = {
  type: 'object',
  properties: {
    isEpic: { type: 'boolean' },
    ready: { type: 'boolean' },
    blockers: { type: 'array', items: { type: 'number' } },
    lane: { type: 'string', enum: ['ui', 'data', 'none'] },
    securitySensitive: { type: 'boolean' },
    docsOnly: { type: 'boolean' },
    userObservable: { type: 'boolean' },
    availableRoles: { type: 'array', items: { type: 'string' } },
    // Custom roles (anything in availableRoles beyond BUILT_IN_ROLES). `applies` is
    // triage's own read of the role's `## Routing` "Spawn when" condition against this
    // issue — the LLM resolves the free-text condition, not this script. `after` is the
    // nearest built-in the role's "Sits" field places it after, constrained to
    // CUSTOM_ROLE_ANCHORS so the script can splice it without parsing prose.
    customRoles: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          kind: { type: 'string', enum: ['builder', 'gate'] },
          applies: { type: 'boolean' },
          after: { type: 'string', enum: CUSTOM_ROLE_ANCHORS },
        },
        required: ['name', 'kind', 'applies'],
      },
    },
    title: { type: 'string' },
    reason: { type: 'string' },
  },
  required: [
    'isEpic', 'ready', 'blockers', 'lane', 'securitySensitive', 'docsOnly',
    'userObservable', 'availableRoles', 'title',
  ],
}

const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    children: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          number: { type: 'number' },
          blockedBy: { type: 'array', items: { type: 'number' } },
          // Per-child routing facts — the planner already knows these because it just
          // labeled each child (lane, priority) and wrote its acceptance criteria. Carrying
          // them here means the workflow can route each child on its own shape instead of
          // the epic's, without a second triage pass per child.
          lane: { type: 'string', enum: ['ui', 'data', 'none'] },
          securitySensitive: { type: 'boolean' },
          docsOnly: { type: 'boolean' },
          userObservable: { type: 'boolean' },
        },
        required: ['number', 'lane', 'securitySensitive', 'docsOnly', 'userObservable'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['children'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['done', 'blocked'] },
    pr: { type: 'string' },
    branch: { type: 'string' },
    summary: { type: 'string' },
  },
  required: ['status', 'summary'],
}

const GATE_SCHEMA = {
  type: 'object',
  properties: {
    status: { type: 'string', enum: ['pass', 'fail'] },
    round: { type: 'number' },
    blocking: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['status', 'summary'],
}

const ACK_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    detail: { type: 'string' },
  },
  required: ['ok'],
}

// §15: the escalation agent also files (or links to) a human:todo issue. todoIssue is
// optional — omitted only if filing itself failed, which escalate() logs as a fallback.
const ESCALATE_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean' },
    detail: { type: 'string' },
    todoIssue: { type: 'number' },
  },
  required: ['ok'],
}

// ------------------------------------------------------------------- routing

// Optional roles are only routable when triage saw them in .claude/agents/.
// If triage could not report the role list, assume built-ins only.
function has(roles, name) {
  return !!roles && roles.indexOf(name) !== -1
}

// §9 last row + templates/custom-agent.md's `## Routing` block: splice any custom role
// triage said applies to this issue into the built-in route. A custom `builder` replaces
// the shape-based builder (mirrors how data-eng already replaces engineer for lane:data);
// a custom `gate` is inserted after the built-in anchor its "Sits" field named, falling
// back to just-before-reviewer when that anchor isn't on this issue's route (e.g. it names
// design-reviewer but design-reviewer isn't installed/applicable here). Returns the
// (possibly mutated) builder/gates plus `unrouted`: role names triage listed in
// availableRoles but never described in customRoles — those got no routing signal at all
// and need a human to dispatch them by hand per §11.5's "log every dropped/skipped item".
function applyCustomRoles(builder, gates, roles, customRoles) {
  const described = customRoles || []
  const applicable = described.filter(function (r) { return r && r.applies })

  const customBuilders = applicable.filter(function (r) { return r.kind === 'builder' })
  if (customBuilders.length) builder = customBuilders[0].name

  const customGates = applicable.filter(function (r) { return r.kind === 'gate' })
  for (let i = 0; i < customGates.length; i++) {
    const r = customGates[i]
    if (r.after === 'start') {
      gates.unshift(r.name)
    } else if (r.after && gates.indexOf(r.after) !== -1) {
      gates.splice(gates.indexOf(r.after) + 1, 0, r.name)
    } else {
      const reviewerIdx = gates.indexOf('reviewer')
      gates.splice(reviewerIdx === -1 ? gates.length : reviewerIdx, 0, r.name)
      log(`custom gate ${r.name}: 'after: ${r.after || '(none)'}' is not on this issue's route — placed just before reviewer`)
    }
  }

  // Only flag a role as unrouted when triage never described it at all — a described role
  // with applies:false is a legitimate non-match (its Spawn-when condition didn't fire for
  // this issue) and would otherwise spam this log on every issue it doesn't apply to.
  const describedNames = described.map(function (r) { return r && r.name })
  const unrouted = (roles || []).filter(function (n) {
    return BUILT_IN_ROLES.indexOf(n) === -1 && describedNames.indexOf(n) === -1
  })

  return { builder: builder, gates: gates, unrouted: unrouted }
}

// §9. Returns { builder, gates: [], unrouted: [] } for one issue given its triage facts.
function routeFor(t) {
  const roles = t.availableRoles || []
  let builder, gates
  if (t.docsOnly) {
    builder = 'engineer'
    gates = ['reviewer']
  } else if (t.lane === 'data') {
    builder = has(roles, 'data-eng') ? 'data-eng' : 'engineer'
    // Fail-safe default: only an explicit `false` drops qa. A missing/omitted
    // userObservable (schema now requires it, but a degraded triage call can still slip
    // one through) must not silently narrow the gate chain on this row of §9.
    gates = t.userObservable === false ? ['reviewer'] : ['qa', 'reviewer']
  } else if (t.lane === 'ui') {
    builder = 'engineer'
    gates = ['qa']
    if (has(roles, 'design-reviewer')) gates.push('design-reviewer')
    gates.push('reviewer')
  } else {
    builder = 'engineer'
    gates = ['qa', 'reviewer']
  }
  // §9's security row overrides the shape-based route: it only ever widens the gate
  // list, never narrows it. Without this, a docsOnly config change to a trust boundary
  // or a securitySensitive lane:data validator with no user-observable surface would
  // skip qa entirely (only routeFor is consulted for gates; modelFor reads
  // securitySensitive too, for the opus bump, but that's a separate concern).
  if (t.securitySensitive && gates.indexOf('qa') === -1) {
    const reviewerIdx = gates.indexOf('reviewer')
    gates.splice(reviewerIdx === -1 ? gates.length : reviewerIdx, 0, 'qa')
  }
  const routed = applyCustomRoles(builder, gates, roles, t.customRoles)
  return { builder: routed.builder, gates: routed.gates, unrouted: routed.unrouted, rolesReported: !!t.availableRoles }
}

function phaseFor(role) {
  if (role === 'reviewer') return 'Review'
  if (BUILT_IN_GATES.indexOf(role) !== -1) return 'QA'
  return 'Review'
}

// §10. Frontmatter carries each role's default; these are the per-call overrides.
function modelFor(role, t) {
  if (role === 'reviewer') return 'opus'
  if (role === 'planner') return 'opus'
  if (role === 'engineer' || role === 'data-eng') return t.securitySensitive ? 'opus' : 'sonnet'
  return 'sonnet'
}

// ------------------------------------------------------------------- prompts

function builderPrompt(number, role, fix) {
  const head = `You are the ${role} working GitHub issue #${number}. ${GH}`
  if (!fix) {
    return (
      head +
      `\n\nImplement it test-first: the red test is its own commit (\`test(#${number}): …\`) ` +
      `before any production commit, on branch \`factory/${number}-<slug>\` cut from the ` +
      `integration branch. Open a draft PR whose body contains \`Closes #${number}\` and your ` +
      `handoff. Post your handoff comment on the issue and move the gate label. ` +
      `Report status (done|blocked), the PR url, the branch, and a one-line summary.`
    )
  }
  const findings = (fix.blocking || []).map(function (b) { return '- ' + b }).join('\n')
  return (
    head +
    `\n\nThe \`${fix.gate}\` gate failed (round ${fix.round}) on your PR${fix.pr ? ' ' + fix.pr : ''}. ` +
    `Its blocking findings:\n${findings || '- see the gate handoff comment on the issue'}\n\n` +
    `Fix exactly these on the same branch and PR, keeping the test-first commit order — a new ` +
    `behavior needs a new red test commit first. Do not re-open settled scope. Post your handoff ` +
    `comment and report status, pr, branch, summary.`
  )
}

function gatePrompt(number, gate, pr) {
  return (
    `You are the ${gate} gate for GitHub issue #${number}. ${GH}\n\n` +
    `The open PR is ${pr || 'linked from the issue'}. Apply your role's evidence bar: only a ` +
    `concrete, reproducible defect is Blocking. Post your handoff comment on the issue and move ` +
    `the gate label per your role prompt. Report status (pass|fail), ROUND (prior ` +
    `\`## Handoff from ${gate}\` comments on this issue with STATUS: fail, plus one), your ` +
    `Blocking findings as separate strings, and a one-line summary.`
  )
}

// ---------------------------------------------------------------- primitives

async function claim(number, builder) {
  const ack = await agent(
    `Housekeeping on GitHub issue #${number}. ${GH}\n\n` +
      `First read the issue's current labels and report them in \`detail\`. Then add the label ` +
      `\`factory:in-progress\`. Remove every \`gate:*\` label already on the issue (the planner ` +
      `may have preset one that doesn't match this route's builder), then add \`gate:${builder}\` ` +
      `(create it if it does not exist) — exactly one \`gate:*\` label must remain, per §3. ` +
      `Change nothing else and post no comment. Report ok.`,
    { label: `claim #${number}`, phase: 'Build', model: 'haiku', schema: ACK_SCHEMA }
  )
  if (!ack || !ack.ok) log(`#${number}: could not set factory:in-progress / gate:${builder} — continuing`)
  return { issue: number, status: 'claimed' }
}

// §3: "Removed on finish." The last gate's pass already added factory:approved and
// removed gate:*; this clears the ownership label so a later hold (PR not merged
// immediately) doesn't leave the issue permanently invisible to §5 readiness / the sweep
// lane, and doesn't trip the orchestrator's "nothing left factory:in-progress that no
// session owns" hygiene check.
async function release(number) {
  const ack = await agent(
    `Housekeeping on GitHub issue #${number}. ${GH}\n\n` +
      `First read the issue's current labels and report them in \`detail\`. The last gate ` +
      `passed and the reviewer's handoff already added \`factory:approved\`, removed all ` +
      `\`gate:*\` labels, and marked the PR ready for review. Remove the label ` +
      `\`factory:in-progress\`. Change nothing else and post no comment. Report ok.`,
    { label: `release #${number}`, phase: 'Review', model: 'haiku', schema: ACK_SCHEMA }
  )
  if (!ack || !ack.ok) log(`#${number}: could not remove factory:in-progress — a human should check labels`)
}

// §15 wiring: a builder that reports `blocked` already files its own human:todo and
// cites it in BLOCKERS (its handoff comment); build.summary often echoes that too. Pull
// the issue number out so escalate() tells the escalation agent not to file a duplicate.
function findTodoIssue(text) {
  if (!text) return null
  const m = /human:todo\D*#(\d+)/i.exec(text) || /\btodo\D*#(\d+)/i.exec(text)
  return m ? Number(m[1]) : null
}

// §8 / §15. Bounce cap hit, or a Worker reported blocked. Either way, files a
// `human:todo` issue alongside the needs-human label and escalation comment — pass
// `existingTodo` when the caller already found one named in the builder's report, so the
// escalation agent links it instead of filing a second one for the same wait.
async function escalate(number, reason, detail, existingTodo) {
  log(`#${number}: ESCALATE — ${reason}`)
  const todoInstruction = existingTodo
    ? `A \`human:todo\` issue #${existingTodo} was already filed for this (cited in the ` +
      `builder's BLOCKERS) — do not file a second one. Just make sure \`- #${existingTodo}\` ` +
      `is under this issue's \`## Blocked by\` section (create the section if absent; on the ` +
      `MCP path, issue_read then issue_write the full body), then report todoIssue: ${existingTodo}.`
    : `File a \`human:todo\` issue with this body (verbatim headings):\n\n` +
      `## What I need from you\n<one paragraph, plain English — the decision or action you ` +
      `owe the factory, and why: is the spec ambiguous, is a finding real but bigger than this ` +
      `issue, or is it an environment problem?>\n\n` +
      `## Steps\n1. <concrete next action — e.g. the command to re-label \`factory:ready\` on ` +
      `#${number} once decided, or the file/spec to amend>\n\n` +
      `## When you're done\nClose this issue, then clear the escalation on #${number}: ` +
      `\`gh issue edit ${number} --remove-label needs-human\` (MCP path: issue_read #${number}, ` +
      `then issue_write the full label array minus \`needs-human\`). Removing that label is ` +
      `what lets the factory pick #${number} up again.\n\n` +
      `## Blocks\n- #${number}\n\n` +
      `Assign it per this order, checking each candidate before use: (1) \`gh api user --jq ` +
      `.login\` when \`gh\` exists, else the \`get_me\` MCP tool; (2) the parent epic's author, ` +
      `then issue #${number}'s own author, in that order — the epic wins when both exist; (3) ` +
      `the repository owner. Human check: before accepting any candidate from (1) or (2), ` +
      `confirm it is a person, not the identity posting this issue (all comments come from one ` +
      `GitHub identity, and planner-filed sub-issues are authored by that same identity) — run ` +
      `\`gh api users/<login> --jq .type\` (or the MCP equivalent) and require \`User\`; reject a ` +
      `login ending in \`[bot]\` or matching the posting identity. Skip a candidate that fails ` +
      `the check and fall through to the next one. If no candidate resolves to a human, file the ` +
      `to-do unassigned and @-mention the candidate humans you found (session user, epic author, ` +
      `issue author, repository owner — whichever are known) in \`## What I need from you\` ` +
      `instead of assigning a machine account. Then add \`- #<todo>\` under ` +
      `#${number}'s \`## Blocked by\` section (create the section if absent; on the MCP path, ` +
      `issue_read then issue_write the full body) and, where the API is reachable, a native ` +
      `blocked-by edge. Report the filed issue's number as todoIssue.`

  const ack = await agent(
    `Escalate GitHub issue #${number} to a human. ${GH}\n\n` +
      `Reason: ${reason}.\n${detail || ''}\n\n` +
      `First read the issue's current labels and report them in \`detail\`. Read the recent ` +
      `handoff comments, then post ONE paragraph: what keeps failing, the gate's last Blocking ` +
      `finding, the builder's last position, and your recommendation (spec ambiguous / finding ` +
      `real but bigger than this issue / environment problem). Add the label \`needs-human\`, ` +
      `remove \`factory:in-progress\`.\n\n${todoInstruction}\n\n` +
      `Do not re-dispatch anything. Report ok and todoIssue.`,
    { label: `escalate #${number}`, phase: 'Escalate', model: 'haiku', schema: ESCALATE_SCHEMA }
  )
  if (!ack || !ack.ok) log(`#${number}: escalation comment may not have posted — a human must be told out of band`)
  const todoIssue = (ack && ack.todoIssue) || existingTodo || null
  if (todoIssue) log(`#${number}: human:todo #${todoIssue}`)
  else log(`#${number}: no human:todo issue number reported — a human should check the issue was filed`)
  return { issue: number, status: 'needs-human', reason: reason, todoIssue: todoIssue }
}

// ------------------------------------------------------------- per-issue loop

async function runIssue(number, t) {
  const route = routeFor(t)
  log(`#${number}: route ${route.builder} → ${route.gates.join(' → ')} (lane=${t.lane}, security=${t.securitySensitive})`)
  if (!route.rolesReported) {
    log(`#${number}: triage reported no role list — routing built-ins only; data-eng/design-reviewer/custom roles will be skipped even if installed`)
  }
  if (route.unrouted.length) {
    log(`#${number}: custom roles not routed by this script — ${route.unrouted.join(', ')}; dispatch them by hand per their ## Routing block`)
  }

  await claim(number, route.builder)

  let build = await agent(builderPrompt(number, route.builder, null), {
    label: `${route.builder} #${number}`,
    phase: 'Build',
    agentType: route.builder,
    model: modelFor(route.builder, t),
    schema: BUILD_SCHEMA,
    // Wave-level fan-out (runWaves → pipeline) can run several issues' builders
    // concurrently in this same script; each needs its own checkout/branch/commits so
    // they don't race on one shared working tree (see §7, §11.2).
    isolation: 'worktree',
  })
  if (!build) return await escalate(number, 'the builder returned nothing (agent died or was skipped)')
  if (build.status !== 'done') return await escalate(number, 'the builder reported blocked', build.summary, findTodoIssue(build.summary))
  log(`#${number}: build done — ${build.pr || 'no PR url reported'} (${build.branch || 'branch not reported'})`)

  for (let g = 0; g < route.gates.length; g++) {
    const gate = route.gates[g]
    let round = 0
    for (;;) {
      const verdict = await agent(gatePrompt(number, gate, build.pr), {
        label: `${gate} #${number}`,
        phase: phaseFor(gate),
        agentType: gate,
        model: modelFor(gate, t),
        schema: GATE_SCHEMA,
        // qa / design-reviewer check out the PR branch to run the app; reviewer only
        // reads committed refs but shares this pool of concurrent gate calls across a
        // wave's issues — isolate all of them so none moves the shared tree's HEAD
        // while a sibling issue's builder or gate is mid-checkout.
        isolation: 'worktree',
      })
      if (!verdict) return await escalate(number, `the ${gate} gate returned nothing (agent died or was skipped)`)

      if (verdict.status === 'pass') {
        log(`#${number}: ${gate} PASS — ${verdict.summary}`)
        break
      }

      // Local counter is authoritative and strictly increases each failed round, so the
      // MAX_ROUNDS cap terminates regardless of what the gate agent reports (round is not
      // independently verifiable here — no filesystem/network from the script). A correctly
      // reporting agent's higher count still wins, e.g. after a resumed/rehydrated run.
      round = Math.max(round + 1, typeof verdict.round === 'number' && verdict.round > 0 ? verdict.round : 0)
      log(`#${number}: ${gate} FAIL round ${round} — ${verdict.summary}`)
      if (round >= MAX_ROUNDS) {
        return await escalate(
          number,
          `${gate} failed ${round} rounds (bounce cap ${MAX_ROUNDS})`,
          `Last blocking findings: ${(verdict.blocking || []).join(' | ') || verdict.summary}`
        )
      }

      const fix = await agent(
        builderPrompt(number, route.builder, {
          gate: gate,
          round: round,
          blocking: verdict.blocking,
          pr: build.pr,
        }),
        {
          label: `${route.builder} fix ${round} #${number}`,
          phase: 'Build',
          agentType: route.builder,
          model: modelFor(route.builder, t),
          schema: BUILD_SCHEMA,
          isolation: 'worktree',
        }
      )
      if (!fix) return await escalate(number, `the builder returned nothing on ${gate} fix round ${round}`)
      if (fix.status !== 'done') return await escalate(number, `the builder reported blocked on ${gate} fix round ${round}`, fix.summary, findTodoIssue(fix.summary))
      if (fix.pr) build = fix
      log(`#${number}: fix round ${round} done — re-running ${gate}`)
    }
  }

  log(`#${number}: approved — ${build.pr || 'PR url not reported'}`)
  await release(number)
  return { issue: number, pr: build.pr || null, status: 'approved', skippedRoles: route.unrouted }
}

// -------------------------------------------------------------- epic → waves

// Each child routes on its OWN shape (lane, docsOnly, securitySensitive,
// userObservable), not the epic's — a lane:data child of a lane:ui epic, or vice versa,
// must not inherit the parent's route. The planner returns these per child (PLAN_SCHEMA);
// fall back to the epic-level triage fact only when the planner omitted a field.
function childFacts(child, epicT) {
  return {
    lane: child.lane || epicT.lane,
    securitySensitive: typeof child.securitySensitive === 'boolean' ? child.securitySensitive : epicT.securitySensitive,
    docsOnly: typeof child.docsOnly === 'boolean' ? child.docsOnly : false,
    userObservable: typeof child.userObservable === 'boolean' ? child.userObservable : epicT.userObservable,
    availableRoles: epicT.availableRoles,
    customRoles: epicT.customRoles,
  }
}

// Run children in dependency waves: everything whose blockers are all approved
// goes at once; repeat until nothing is left or a wave makes no progress.
async function runWaves(children, t) {
  const pending = new Map()
  for (let i = 0; i < children.length; i++) pending.set(children[i].number, children[i])
  const approved = new Set()
  const stopped = new Set()
  const results = []
  let wave = 0

  while (pending.size > 0) {
    const runnable = []
    const dropped = []
    const values = Array.from(pending.values())
    for (let i = 0; i < values.length; i++) {
      const c = values[i]
      const deps = c.blockedBy || []
      let blockedByFailure = false
      let waiting = false
      for (let d = 0; d < deps.length; d++) {
        const b = deps[d]
        if (stopped.has(b)) blockedByFailure = true
        else if (pending.has(b) && b !== c.number) waiting = true
      }
      if (blockedByFailure) dropped.push(c)
      else if (!waiting) runnable.push(c)
    }

    for (let i = 0; i < dropped.length; i++) {
      pending.delete(dropped[i].number)
      stopped.add(dropped[i].number)
      log(`#${dropped[i].number}: skipped — a blocker did not reach approved`)
      results.push({ issue: dropped[i].number, status: 'skipped', reason: 'blocker not approved' })
    }

    if (runnable.length === 0) {
      if (pending.size > 0) {
        const stuck = Array.from(pending.keys())
        log(`dependency cycle or unresolvable blockers among ${stuck.join(', ')} — left for a human`)
        // §15: this is a substantial human ask (break a dependency cycle or fix a stale
        // blocker) — a log line in a job/session transcript nobody reopens is not a record
        // of it. File one human:todo on the epic naming every stuck child, instead of
        // leaving this as log-only.
        const stuckList = stuck.join(', #')
        const todoAck = await agent(
          `File a \`human:todo\` GitHub issue blocking epic #${ISSUE}. ${GH}\n\n` +
            `Sub-issues #${stuckList} of epic #${ISSUE} cannot make progress: each is still ` +
            `waiting on a \`## Blocked by\` blocker that will never close on its own — a ` +
            `dependency cycle among them, or a blocker outside this wave that isn't closing. ` +
            `Use this body (verbatim headings):\n\n` +
            `## What I need from you\nEpic #${ISSUE}'s sub-issues #${stuckList} are stuck on ` +
            `unresolvable \`## Blocked by\` dependencies — the factory found no order in which ` +
            `any of them is ready to run.\n\n` +
            `## Steps\n1. Open #${stuckList} and read each one's \`## Blocked by\` section.\n` +
            `2. Find the cycle (or the blocker that will never close) and break it by editing ` +
            `those \`## Blocked by\` sections — drop the stale entry or reorder the real ` +
            `dependency.\n3. Re-label the affected issues \`factory:ready\`.\n\n` +
            `## When you're done\nClose this issue once the blockers are fixed and the affected ` +
            `issues are re-labeled \`factory:ready\` — that's what lets the factory pick them up ` +
            `again.\n\n## Blocks\n- #${ISSUE}\n\n` +
            `Assign it per §15's order, checking each candidate before use: (1) \`gh api user ` +
            `--jq .login\` when \`gh\` exists, else the \`get_me\` MCP tool; (2) epic #${ISSUE}'s ` +
            `author; (3) the repository owner. Human check: before accepting (1) or (2), confirm ` +
            `it is a person, not the identity posting this issue — run \`gh api users/<login> ` +
            `--jq .type\` (or the MCP equivalent) and require \`User\`; reject a login ending in ` +
            `\`[bot]\` or matching the posting identity, and fall through to the next candidate ` +
            `on failure. If no candidate resolves to a human, file the to-do unassigned and ` +
            `@-mention the known candidates (session user, epic author, repository owner) in ` +
            `\`## What I need from you\` instead of assigning a machine account. Then ` +
            `add \`- #<todo>\` under #${ISSUE}'s \`## Blocked by\` section (create the section if ` +
            `absent; on the MCP path, issue_read then issue_write the full body). Do not add ` +
            `\`needs-human\` to #${ISSUE} or to any of #${stuckList} — that label is reserved for ` +
            `a §8 gate bounce-cap escalation, and this isn't one. Report the filed issue's number ` +
            `as todoIssue.`,
          { label: `todo #${ISSUE} stuck children`, phase: 'Escalate', model: 'haiku', schema: ESCALATE_SCHEMA }
        )
        const todoIssue = (todoAck && todoAck.todoIssue) || null
        if (todoIssue) log(`#${ISSUE}: human:todo #${todoIssue} filed for stuck children #${stuckList}`)
        else log(`#${ISSUE}: could not confirm a human:todo was filed for stuck children #${stuckList} — a human should check`)
        for (let i = 0; i < stuck.length; i++) results.push({ issue: stuck[i], status: 'stalled', reason: 'unresolvable blockers', todoIssue: todoIssue })
      }
      break
    }

    wave++
    for (let i = 0; i < runnable.length; i++) pending.delete(runnable[i].number)
    log(`wave ${wave}: ${runnable.map(function (c) { return '#' + c.number }).join(', ')}`)

    const out = await pipeline(runnable, function (item) {
      return runIssue(item.number, childFacts(item, t))
    })

    for (let i = 0; i < runnable.length; i++) {
      const n = runnable[i].number
      const r = out[i]
      if (r && r.status === 'approved') approved.add(n)
      else stopped.add(n)
      results.push(r || { issue: n, status: 'error', reason: 'workflow stage threw' })
    }
  }

  return results
}

// ---------------------------------------------------------------------- main

if (!ISSUE) {
  log('no issue number in args — call this workflow with args { issue: <number> }')
  return { status: 'error', reason: 'missing args.issue' }
}

phase('Triage')
log(`triaging #${ISSUE} in ${REPO}`)

const triage = await agent(
  `Triage GitHub issue #${ISSUE}. ${GH}\n\n` +
    `Report, without changing anything:\n` +
    `- isEpic: it carries the \`type:epic\` label.\n` +
    `- ready: open AND labeled \`factory:ready\` AND not \`factory:in-progress\` AND not ` +
    `\`needs-human\` AND every issue in its \`## Blocked by\` body section and every native ` +
    `blocked-by edge is closed.\n` +
    `- blockers: the still-open blocker issue numbers.\n` +
    `- lane: "ui" or "data" from a \`lane:*\` label, else "none".\n` +
    `- securitySensitive: it touches auth, a trust boundary, secrets, or a security-relevant validator.\n` +
    `- docsOnly: docs, copy or config only.\n` +
    `- userObservable: the change has a surface a user or an API client can observe.\n` +
    `- availableRoles: the role names defined in \`.claude/agents/\` (filenames without .md).\n` +
    `- customRoles: for every name in availableRoles beyond planner, engineer, data-eng, qa, ` +
    `design-reviewer, reviewer, read its \`## Routing\` block in \`.claude/agents/<name>.md\` ` +
    `and report { name, kind ('builder' or 'gate', from its Kind field), applies (your own ` +
    `judgment: does this issue match its "Spawn when" condition?), after (from its "Sits" ` +
    `field: the nearest built-in role it sits after — one of start, engineer, data-eng, qa, ` +
    `design-reviewer, reviewer; use "start" if it sits before/instead of the builder) }.\n` +
    `- title, and reason if not ready.`,
  { label: `triage #${ISSUE}`, phase: 'Triage', model: 'haiku', schema: TRIAGE_SCHEMA }
)

if (!triage) {
  log(`#${ISSUE}: triage returned nothing — stopping without touching the issue`)
  return { issue: ISSUE, status: 'error', reason: 'triage agent returned null' }
}

log(`#${ISSUE}: "${triage.title}" epic=${triage.isEpic} ready=${triage.ready} lane=${triage.lane} roles=${(triage.availableRoles || []).join(',') || 'unknown'}`)

if (!triage.ready) {
  const why = triage.reason || (triage.blockers && triage.blockers.length ? `open blockers: ${triage.blockers.join(', ')}` : 'not eligible for dispatch')
  log(`#${ISSUE}: not ready — ${why}. Nothing dispatched.`)
  return { issue: ISSUE, status: 'not-ready', reason: why, blockers: triage.blockers || [] }
}

if (!triage.isEpic) {
  const result = await runIssue(ISSUE, triage)
  return { issue: ISSUE, title: triage.title, status: result.status, pr: result.pr || null, results: [result] }
}

phase('Plan')
log(`#${ISSUE} is an epic — planning sub-issues`)

const plan = await agent(
  `You are the planner for epic GitHub issue #${ISSUE}. ${GH}\n\n` +
    `Decompose it into sub-issues, each one independently shippable and self-sufficient: a ` +
    `Worker must be able to start from the issue body and its comments alone. Use the issue body ` +
    `template from your role prompt — Source, Acceptance criteria as a red-test list, Out of ` +
    `scope, Notes for the builder, and \`## Blocked by\` for real ordering or shared-file ` +
    `constraints only. File them as sub-issues of #${ISSUE}, set native blocked-by edges where ` +
    `the API is reachable, and label each \`factory:ready\` plus its own lane and priority — ` +
    `each child may need a different lane than the epic. Return every child you filed with ` +
    `its blockedBy list (child issue numbers only) and its own lane, securitySensitive, ` +
    `docsOnly, and userObservable so the workflow can route it without re-triaging.`,
  { label: `planner #${ISSUE}`, phase: 'Plan', agentType: 'planner', model: 'opus', schema: PLAN_SCHEMA }
)

if (!plan || !plan.children || plan.children.length === 0) {
  log(`#${ISSUE}: the planner filed no sub-issues — stopping`)
  return { issue: ISSUE, status: 'error', reason: 'planner returned no children' }
}

log(`#${ISSUE}: ${plan.children.length} sub-issues filed — ${plan.children.map(function (c) { return '#' + c.number }).join(', ')}`)

// runWaves derives each child's own route from its planner-reported lane/docsOnly/
// securitySensitive/userObservable (see childFacts() above), falling back to these
// epic-level triage facts only for whatever a child omitted.
const results = await runWaves(plan.children, triage)
const approvedCount = results.filter(function (r) { return r && r.status === 'approved' }).length
log(`#${ISSUE}: ${approvedCount}/${results.length} sub-issues approved`)

return {
  issue: ISSUE,
  title: triage.title,
  status: approvedCount === results.length ? 'approved' : 'partial',
  children: results,
}
