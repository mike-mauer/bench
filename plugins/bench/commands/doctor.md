---
name: doctor
description: Read-only health check of the Bench harness install in this project — verifies bd is present at the pinned version, the plugin + its beads dependency are active, the CLAUDE.md orchestrator block is present and current, and reports anything that needs /bench:init or a manual fix. Does not modify anything.
---

# /bench:doctor — verify the Bench harness install

Run a **read-only** diagnostic of the Bench harness in the current project and print a
concise report. Do not modify any files. For each item, show ✅ / ⚠️ and the fix command.

1. **bd binary** — `command -v bd` and `bd version`. Compare against the configured pin
   (the plugin's `bd_version`, default `1.0.4`). Missing → note that the SessionStart
   `install-bd` hook installs it (may still be running in the background; check
   `/tmp/bench-install-bd.log`). Version mismatch → ⚠️ (the `beads-health-check` skill
   covers version-drift policy).
2. **Plugins active** — `claude plugin list` should show `bench` enabled and its `beads`
   dependency enabled. Missing beads → ⚠️ (`claude plugin install beads@beads-marketplace`).
3. **Beads board** — `.beads/` exists and `bd ready` returns without error. Cold/empty board
   → note the `beads-bootstrap` hook rehydrates it, or run `bd bootstrap` manually.
4. **CLAUDE.md block** — `CLAUDE.md` contains a `<!-- BEGIN BENCH ... -->` block. Extract its
   `hash:` and compare to the bundled template's hash:
   ```bash
   if command -v sha256sum >/dev/null 2>&1; then WANT=$(sha256sum "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md" | cut -c1-8)
   else WANT=$(shasum -a 256 "${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE.bench.md" | cut -c1-8); fi
   HAVE=$(grep -o 'BEGIN BENCH[^>]*hash:[0-9a-f]*' CLAUDE.md 2>/dev/null | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)
   echo "want=$WANT have=$HAVE"
   ```
   Absent or stale → ⚠️ run `/bench:init` to install/refresh the orchestrator rules.
5. **Hooks duplication** — inspect the project's `.claude/settings.json`. If it still has a
   hand-rolled `bd prime` SessionStart hook, ⚠️ it double-fires with the plugin/beads hooks →
   run `/bench:init` (Step 3) to remove it.
6. **Optional roles** — report which of `data-eng` / `design-reviewer` exist in
   `.claude/agents/`, and flag any still containing `<<FILL: ...>>` placeholders.
7. **Worktrees** — report the count under `.claude/worktrees/` (the SessionStart
   `worktree-reap` hook prunes merged/stale ones).
8. **Board engine mode** — `bd info` (or `bd dolt show`); report `Mode:` (Bench's default is
   embedded `direct`). Bench runs **every role's `bd` directly** against this one shared board —
   agents reach it from worktrees via git-common-dir discovery — so in embedded mode there is no
   server to check. **Do not run `bd doctor`** — it is unsupported in embedded mode.

End with a one-line summary and, for any ⚠️, the exact command to resolve it. For a deep
board audit, point the user at the `beads-health-check` skill.
