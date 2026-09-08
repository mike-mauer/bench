#!/usr/bin/env bash
# scripts/cloud-install.sh — bootstrap Bench v2 into a project from a plain
# shell, no Claude CLI and no marketplace plugin ever loaded (a cloud/web
# session on a project that never had Bench, or any fresh container).
#
#   curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
#   curl -fsSL <same url> | bash -s -- --with data-eng --dispatch action
#
# Idempotent, re-runnable steps: (1) copy agents/{planner,engineer,qa,reviewer}.md
# into .claude/agents/ — plugin-owned, always overwritten — plus any --with role
# from agents-optional/, never overwritten once a project has its own copy;
# (2) copy skills/bench-orchestrator/SKILL.md into .claude/skills/bench-orchestrator/
# — plugin-owned, always overwritten; the managed CLAUDE.md block this script
# injects in step (5) requires invoking that skill before any dispatch beyond a
# single-file edit, so without this copy that instruction is unfollowable in
# exactly the environment this script targets; (3) copy workflows/factory.js into
# .claude/workflows/; (4) copy scripts/{factory-ready.sh,gh-issue-dep.sh,
# tdd-order-check.sh} into .claude/scripts/ (chmod +x) — the sweep lane, planner
# dependency edges, and the TDD-order CI check all resolve `scripts/...` to this
# project-owned copy, not the plugin's; (5) inject/refresh the managed CLAUDE.md
# block (marker `<!-- BEGIN BENCH v:2 hash:XXXX -->`, hash from the canonical
# scripts/bench-hash.sh so /bench:doctor and the drift-check hook agree);
# (6) --dispatch action|routine copies that dispatch template into
# .github/workflows/factory-dispatch.yml (skipped if it already exists — may be
# a customization, left for a human); (7) best-effort `gh label create --force`
# for just `human:todo` and `needs-human` when `gh` is authenticated — without
# these two labels, protocol §15's "file a human:todo" instruction fails on
# every role prompt and the factory workflow's escalation step, on exactly the
# repo this script is for (the plugin, and therefore /bench:init, never
# loaded). Warns and moves on otherwise; the full §3 label set is still
# /bench:init's job once it can run.
#
# No .claude/settings.json, no git commit — that's /bench:init (once the
# plugin loads) or a human. Past the two labels in step (7), this script only
# places files.
#
# Sources from BENCH_REPO@BENCH_REF over curl/wget by default. Set
# BENCH_SOURCE_DIR=<path to a plugins/bench checkout> to read from disk
# instead — used by tests/cloud_install.bats to run fully offline.
set -uo pipefail

BENCH_REPO="${BENCH_REPO:-mike-mauer/bench}"
BENCH_REF="${BENCH_REF:-main}"
BENCH_SOURCE_DIR="${BENCH_SOURCE_DIR:-}"
BUILTIN_AGENTS="planner engineer qa reviewer"
BUILTIN_SCRIPTS="factory-ready.sh gh-issue-dep.sh tdd-order-check.sh"

PROJECT_DIR=""
WITH_ROLES=""
DISPATCH=""
DRY_RUN=0
AGENTS_FAILED=0

log()  { printf '[bench-cloud-install] %s\n' "$*" >&2; }
warn() { printf '[bench-cloud-install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bench-cloud-install] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
bench cloud-install — install Bench v2 into this project from a plain shell.

Usage:
  curl -fsSL https://raw.githubusercontent.com/mike-mauer/bench/main/plugins/bench/scripts/cloud-install.sh | bash
  curl -fsSL <same url> | bash -s -- [options]

Options:
  --project-dir <path>  Project to install into (default: git toplevel, else $PWD).
  --with <roles>        Comma-separated optional roles: data-eng, design-reviewer.
  --dispatch <lane>     action | routine — install that dispatch workflow template.
  --dry-run             Report what would change; write nothing.
  -h, --help            This help.

Env: BENCH_REPO (default mike-mauer/bench), BENCH_REF (default main),
BENCH_SOURCE_DIR (read from a local plugins/bench checkout instead of the network).

Afterwards: review, commit CLAUDE.md/.claude//.github/workflows, and run
/bench:init next session for labels and settings that need the loaded plugin.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="${2:-}"; [ -n "$PROJECT_DIR" ] || die "--project-dir needs a path"; shift 2 ;;
    --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
    --with) WITH_ROLES="${2:-}"; [ -n "$WITH_ROLES" ] || die "--with needs a role list"; shift 2 ;;
    --with=*) WITH_ROLES="${1#*=}"; shift ;;
    --dispatch) DISPATCH="${2:-}"; [ -n "$DISPATCH" ] || die "--dispatch needs action|routine"; shift 2 ;;
    --dispatch=*) DISPATCH="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
case "$DISPATCH" in "" | action | routine) : ;; *) die "--dispatch must be action or routine" ;; esac

if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$PROJECT_DIR" ] || PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
fi
[ -d "$PROJECT_DIR" ] || die "project dir does not exist: $PROJECT_DIR"
cd "$PROJECT_DIR" || die "cannot cd into $PROJECT_DIR"
PROJECT_DIR="$PWD"
log "project: $PROJECT_DIR"
[ "$DRY_RUN" -eq 1 ] && log "DRY RUN — nothing will be written."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1" 2>/dev/null
  else return 1; fi
}

# plugin_file <path-relative-to-plugins/bench> → echoes a readable local path,
# from BENCH_SOURCE_DIR if set, else fetched into $TMP from BENCH_REPO@BENCH_REF.
plugin_file() {
  rel="$1"
  if [ -n "$BENCH_SOURCE_DIR" ]; then
    [ -f "$BENCH_SOURCE_DIR/$rel" ] || return 1
    printf '%s\n' "$BENCH_SOURCE_DIR/$rel"; return 0
  fi
  dest="$TMP/$rel"
  if [ ! -s "$dest" ]; then
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    fetch "https://raw.githubusercontent.com/$BENCH_REPO/$BENCH_REF/plugins/bench/$rel" "$dest" || return 1
    [ -s "$dest" ] || return 1
  fi
  printf '%s\n' "$dest"
}

# install_file <rel> <dest> <label> — copy, or report, honoring --dry-run.
# Returns the plugin_file failure code untouched so callers can react.
install_file() {
  src="$(plugin_file "$1")" || return 1
  if [ "$DRY_RUN" -eq 1 ]; then log "would write $3"; return 0; fi
  mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
  cp -f "$src" "$2" 2>/dev/null
}

# Step 1 — role agents.
for role in $BUILTIN_AGENTS; do
  if install_file "agents/$role.md" "$PROJECT_DIR/.claude/agents/$role.md" ".claude/agents/$role.md"; then
    [ "$DRY_RUN" -eq 0 ] && log "agents: installed $role → .claude/agents/$role.md"
  else
    warn "agents: could not fetch/write agents/$role.md"
    AGENTS_FAILED=1
  fi
done

if [ -n "$WITH_ROLES" ]; then
  IFS=','; for role in $WITH_ROLES; do
    IFS=' '
    role="$(printf '%s' "$role" | tr -d '[:space:]')"
    [ -n "$role" ] || continue
    dest="$PROJECT_DIR/.claude/agents/$role.md"
    if [ -f "$dest" ]; then
      log "roles: $role already installed — left as is."
    elif install_file "agents-optional/$role.md" "$dest" ".claude/agents/$role.md"; then
      [ "$DRY_RUN" -eq 0 ] && log "roles: installed $role → .claude/agents/$role.md (fill any <<FILL: ...>> placeholders)."
    else
      warn "roles: unknown or unavailable role '$role' (have: data-eng, design-reviewer)."
    fi
    IFS=','
  done
  unset IFS
fi

# Step 2 — the bench-orchestrator skill. Hard-required like the agents: the
# managed CLAUDE.md block installed in Step 4 orders every dispatch beyond a
# single-file edit to invoke this skill first, and a cloud/CI environment can't
# fall back to the marketplace plugin's copy — it never loads one.
if install_file "skills/bench-orchestrator/SKILL.md" "$PROJECT_DIR/.claude/skills/bench-orchestrator/SKILL.md" ".claude/skills/bench-orchestrator/SKILL.md"; then
  [ "$DRY_RUN" -eq 0 ] && log "skill: installed .claude/skills/bench-orchestrator/SKILL.md"
else
  warn "skill: could not fetch/write skills/bench-orchestrator/SKILL.md"
  AGENTS_FAILED=1
fi

# Step 3 — the factory workflow.
if install_file "workflows/factory.js" "$PROJECT_DIR/.claude/workflows/factory.js" ".claude/workflows/factory.js"; then
  [ "$DRY_RUN" -eq 0 ] && log "workflow: installed .claude/workflows/factory.js"
else
  warn "workflow: could not fetch/write workflows/factory.js"
fi

# Step 4 — the scripts role prompts, the sweep lane, and CI reference by bare
# `scripts/...` path. Same overwrite-on-rerun, warn-on-failure treatment as the
# workflow (not hard-required to install at all — a project can still dispatch
# roles by hand — but every fresh copy should be current and executable).
for s in $BUILTIN_SCRIPTS; do
  dest="$PROJECT_DIR/.claude/scripts/$s"
  if install_file "scripts/$s" "$dest" ".claude/scripts/$s"; then
    if [ "$DRY_RUN" -eq 0 ]; then
      chmod +x "$dest" 2>/dev/null || warn "scripts: installed $s but could not chmod +x it"
      log "scripts: installed $s → .claude/scripts/$s"
    fi
  else
    warn "scripts: could not fetch/write scripts/$s"
  fi
done

# Step 5 — the managed CLAUDE.md orchestrator block.
inject_claudemd() {
  tpl="$(plugin_file 'templates/CLAUDE.bench.md')" || { warn "CLAUDE.md: could not read templates/CLAUDE.bench.md — skipped."; return 1; }
  hasher="$(plugin_file 'scripts/bench-hash.sh')"  || { warn "CLAUDE.md: could not read scripts/bench-hash.sh — skipped."; return 1; }
  h="$(bash "$hasher" "$tpl" 2>/dev/null)"
  [ -n "$h" ] || { warn "CLAUDE.md: could not compute the template hash — skipped."; return 1; }

  target="$PROJECT_DIR/CLAUDE.md"
  block="$TMP/block.md"
  { printf '<!-- BEGIN BENCH v:2 hash:%s -->\n' "$h"; cat "$tpl"; printf '<!-- END BENCH -->\n'; } > "$block"

  have_begin=0; have_end=0
  if [ -f "$target" ]; then
    grep -q '^<!-- BEGIN BENCH' "$target" && have_begin=1
    grep -q '^<!-- END BENCH -->' "$target" && have_end=1
  fi

  if [ "$have_begin" -eq 1 ] && [ "$have_end" -eq 0 ]; then
    warn "CLAUDE.md: has a BEGIN BENCH marker but no END BENCH — refusing to touch it."
    return 1
  fi

  if [ "$have_begin" -eq 1 ]; then
    cur="$(grep -o '^<!-- BEGIN BENCH[^>]*hash:[0-9a-f]*' "$target" 2>/dev/null | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)"
    if [ "$cur" = "$h" ]; then log "CLAUDE.md: orchestrator block already current (hash:$h)."; return 0; fi
    if [ "$DRY_RUN" -eq 1 ]; then log "CLAUDE.md: would refresh the orchestrator block (hash:${cur:-none} → $h)."; return 0; fi
    awk -v bf="$block" '
      /^<!-- BEGIN BENCH/ && !replaced { while ((getline line < bf) > 0) print line; close(bf); skip=1; replaced=1; next }
      skip && /^<!-- END BENCH -->/ { skip=0; next }
      !skip { print }
    ' "$target" > "$TMP/claude.md.new" && mv -f "$TMP/claude.md.new" "$target" \
      || { warn "CLAUDE.md: rewrite failed — left untouched."; return 1; }
    log "CLAUDE.md: refreshed the orchestrator block (hash:${cur:-none} → $h)."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then log "CLAUDE.md: would add the orchestrator block (hash:$h)."; return 0; fi
  [ -f "$target" ] && printf '\n' >> "$target"
  cat "$block" >> "$target" || { warn "CLAUDE.md: could not write $target."; return 1; }
  log "CLAUDE.md: added the orchestrator block (hash:$h)."
}
inject_claudemd

# Step 6 — dispatch lane (optional).
if [ -n "$DISPATCH" ]; then
  dest="$PROJECT_DIR/.github/workflows/factory-dispatch.yml"
  if [ -f "$dest" ]; then
    log "dispatch: .github/workflows/factory-dispatch.yml already exists — left as is (may be customized)."
  elif install_file "templates/factory-dispatch-$DISPATCH.yml" "$dest" ".github/workflows/factory-dispatch.yml"; then
    [ "$DRY_RUN" -eq 0 ] && log "dispatch: installed the $DISPATCH lane → .github/workflows/factory-dispatch.yml"
  else
    warn "dispatch: could not fetch/write templates/factory-dispatch-$DISPATCH.yml"
  fi
fi

# Step 7 — the two labels protocol §15 needs (best-effort). `gh issue create
# --label` fails the whole command, issue and all, when a label doesn't exist
# — so without this, a role that hits `STATUS: blocked` on a repo /bench:init
# never ran on can't file the human:todo it just decided it needs, and the ask
# is silently lost. Only human:todo and needs-human: enough for §15 filings
# and §8 escalations to succeed; /bench:init still creates the rest of §3's
# label set once the plugin loads.
gh_retry() { if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"; else "$@"; fi; }
if [ "$DRY_RUN" -eq 1 ]; then
  log "would create labels: human:todo, needs-human (skipped — dry run)"
elif ! command -v gh >/dev/null 2>&1; then
  warn "labels: gh not on PATH — create human:todo (B60205) and needs-human (B60205) by hand, or once /bench:init can run (protocol §3)."
elif ! gh_retry gh auth status >/dev/null 2>&1; then
  warn "labels: gh is not authenticated — create human:todo (B60205) and needs-human (B60205) by hand, or once /bench:init can run (protocol §3)."
else
  for l in "human:todo:B60205" "needs-human:B60205"; do
    name="${l%:*}"; color="${l##*:}"
    if gh_retry gh label create "$name" --color "$color" --force >/dev/null 2>&1; then
      log "labels: created/updated $name"
    else
      warn "labels: could not create $name — create it by hand (protocol §3)."
    fi
  done
fi

# Report.
echo >&2
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run complete — nothing was written."
elif [ "$AGENTS_FAILED" -eq 0 ]; then
  log "done. Review, then commit: git add CLAUDE.md .claude .github/workflows"
  log "Run /bench:init next session (labels + anything needing the loaded plugin), then /bench:doctor."
else
  log "done, but with failures — see the warnings above."
fi

[ "$AGENTS_FAILED" -eq 1 ] && die "could not write one or more of: $BUILTIN_AGENTS, or the bench-orchestrator skill — the harness has no roles, or no dispatch playbook, without these."
exit 0
