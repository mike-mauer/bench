#!/usr/bin/env bash
# scripts/bench-hash.sh — canonical 8-char content hash of the file given as $1.
#
# Single source of truth for the hash format used in the CLAUDE.md orchestrator
# block marker (`<!-- BEGIN BENCH v:N hash:XXXX -->`). /bench:init writes this
# hash, and /bench:doctor and the claudemd-drift-check hook compare against it —
# all three MUST agree on the fallback chain, or a system missing a sha tool
# writes one format at init time and computes another at check time, producing a
# permanent phantom "stale" warning. Change the chain here and nowhere else.
#
# Chain: sha256sum (Linux) → shasum -a 256 (macOS) → cksum (POSIX baseline).
# On sha-capable systems the output is the first 8 hex chars of the sha256.
set -uo pipefail

[ -n "${1:-}" ] && [ -f "$1" ] || { echo "usage: bench-hash.sh <file>" >&2; exit 1; }

if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-8
elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-8
else cksum "$1" | awk '{print $1}'; fi
