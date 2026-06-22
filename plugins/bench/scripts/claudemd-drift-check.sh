#!/usr/bin/env bash
# scripts/claudemd-drift-check.sh — SessionStart hook: warn when the Bench block in
# the project's CLAUDE.md is stale relative to the version the plugin ships.
#
# `claude plugin update bench` refreshes the agents/skills/hooks/scripts immediately,
# but the always-on orchestrator rules that /bench:init injected into the project's
# CLAUDE.md only refresh when init re-runs. This hook closes that gap: it compares
# the content hash recorded in the project's `<!-- BEGIN BENCH v:N hash:XXXX -->`
# marker against the hash of the bundled template, and warns (read-only) when they
# differ or the block is absent. It NEVER edits CLAUDE.md.
#
# Best-effort: every path exits 0.
set -uo pipefail

log() { printf '[bench-drift] %s\n' "$*" >&2; }

PROJECT="${CLAUDE_PROJECT_DIR:-$PWD}"
TEMPLATE="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/templates/CLAUDE.bench.md"
CLAUDEMD="$PROJECT/CLAUDE.md"

[ -f "$TEMPLATE" ] || exit 0

# Portable 8-char content hash (sha256sum on Linux, shasum -a 256 on macOS).
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-8
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-8
  else cksum "$1" | awk '{print $1}'; fi
}

want="$(hash_file "$TEMPLATE")"

if [ ! -f "$CLAUDEMD" ] || ! grep -q 'BEGIN BENCH' "$CLAUDEMD" 2>/dev/null; then
  log "no Bench block found in CLAUDE.md — run /bench:init to install the orchestrator rules."
  exit 0
fi

have="$(grep -o 'BEGIN BENCH[^>]*hash:[0-9a-f]*' "$CLAUDEMD" 2>/dev/null | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)"

if [ -n "$have" ] && [ "$have" != "$want" ]; then
  log "the Bench block in CLAUDE.md is stale (have ${have}, ships ${want}) — run /bench:init to refresh."
fi
exit 0
