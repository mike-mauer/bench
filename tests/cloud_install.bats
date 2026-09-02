#!/usr/bin/env bats
# Tests for plugins/bench/scripts/cloud-install.sh — the curl-able installer that
# makes a project Bench-enabled from inside a Claude Code cloud/web session,
# where `claude plugin install` (user scope) and `/bench:init` (ships inside the
# not-yet-loaded plugin) are both unavailable.
#
# The contract under test:
#   • `.claude/settings.json` gets the marketplace + enabledPlugins entries that
#     web sessions load plugins from — MERGED, never clobbering unrelated keys,
#     never duplicating entries on a re-run. This step is the whole point of the
#     script, so its failure is the one thing that makes it exit non-zero.
#   • Config it did not write is refused, not overwritten (an object-shaped
#     `enabledPlugins`, a `CLAUDE.md` with unbalanced BENCH markers).
#   • The CLAUDE.md marker hash comes from the canonical scripts/bench-hash.sh —
#     if the installer ever re-implemented it, every session would warn "stale".
#   • `--dry-run` writes nothing at all.
#
# Hermetic: every test runs the script from this checkout (so it uses the local
# plugin root and never fetches) with --no-bd (so it never downloads a binary).

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/cloud-install.sh"
HASHER="$BATS_TEST_DIRNAME/../plugins/bench/scripts/bench-hash.sh"
TEMPLATE="$BATS_TEST_DIRNAME/../plugins/bench/templates/CLAUDE.bench.md"

setup() {
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
}

run_install() { run bash "$SCRIPT" --project-dir "$PROJ" --no-bd "$@"; }

# Value of a jq-ish query without depending on jq being installed.
py() { python3 -c "$1" "$PROJ/.claude/settings.json"; }

@test "fresh project: writes the marketplace + enabledPlugins entries web sessions need" {
  run_install

  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/settings.json" ]
  run py 'import json,sys; d=json.load(open(sys.argv[1])); print(d["extraKnownMarketplaces"]["bench"]["source"]["repo"], d["extraKnownMarketplaces"]["beads-marketplace"]["source"]["repo"])'
  [ "$output" = "mike-mauer/bench gastownhall/beads" ]
  run py 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted((e["marketplace"],e["plugin"]) for e in d["enabledPlugins"]))'
  [[ "$output" == *"('beads-marketplace', 'beads')"* ]]
  [[ "$output" == *"('bench', 'bench')"* ]]
}

@test "fresh project: CLAUDE.md block carries the canonical bench-hash.sh hash" {
  run_install
  [ "$status" -eq 0 ]

  want="$(bash "$HASHER" "$TEMPLATE")"
  have="$(grep -o 'BEGIN BENCH[^>]*hash:[0-9a-f]*' "$PROJ/CLAUDE.md" | grep -o 'hash:[0-9a-f]*' | head -1 | cut -d: -f2)"
  [ -n "$want" ]
  [ "$have" = "$want" ]
  grep -q '<!-- END BENCH -->' "$PROJ/CLAUDE.md"
  # The block is the template verbatim, not a paraphrase.
  grep -q 'Bench harness — operating rules' "$PROJ/CLAUDE.md"
}

@test "re-run is idempotent: no duplicate plugin entries, no second CLAUDE.md block" {
  run_install
  [ "$status" -eq 0 ]
  run_install

  [ "$status" -eq 0 ]
  [[ "$output" == *"already enables bench + beads"* ]]
  [[ "$output" == *"already current"* ]]
  run py 'import json,sys; print(len(json.load(open(sys.argv[1]))["enabledPlugins"]))'
  [ "$output" = "2" ]
  [ "$(grep -c 'BEGIN BENCH' "$PROJ/CLAUDE.md")" -eq 1 ]
}

@test "merges into an existing settings.json: unrelated keys and plugins survive" {
  mkdir -p "$PROJ/.claude"
  cat > "$PROJ/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(bd *)"] },
  "hooks": { "SessionStart": [] },
  "extraKnownMarketplaces": { "other": { "source": { "source": "github", "repo": "acme/other" } } },
  "enabledPlugins": [ { "marketplace": "other", "plugin": "widget" } ]
}
JSON

  run_install

  [ "$status" -eq 0 ]
  run py 'import json,sys; d=json.load(open(sys.argv[1])); print(d["permissions"]["allow"][0], "SessionStart" in d["hooks"], sorted(d["extraKnownMarketplaces"]), len(d["enabledPlugins"]))'
  [ "$output" = "Bash(bd *) True ['beads-marketplace', 'bench', 'other'] 3" ]
}

@test "an object-shaped enabledPlugins is refused, left intact, and fails loudly" {
  mkdir -p "$PROJ/.claude"
  echo '{"enabledPlugins":{"bench@bench":true}}' > "$PROJ/.claude/settings.json"
  before="$(cat "$PROJ/.claude/settings.json")"

  run_install --no-claudemd

  # The settings step is the point of the script — its failure is a real failure.
  [ "$status" -eq 1 ]
  [ "$(cat "$PROJ/.claude/settings.json")" = "$before" ]
  [[ "$output" == *"refusing to rewrite"* ]]
  # …and it prints the snippet to merge by hand.
  [[ "$output" == *'"extraKnownMarketplaces"'* ]]
}

@test "a stale CLAUDE.md block is refreshed in place, leaving other content alone" {
  want="$(bash "$HASHER" "$TEMPLATE")"
  {
    printf '# My Project\n\nsome project rules\n\n'
    printf '<!-- BEGIN BENCH v:1 hash:deadbeef -->\nOLD BENCH RULES\n<!-- END BENCH -->\n\n'
    printf '<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->\nbeads block\n<!-- END BEADS INTEGRATION -->\n'
  } > "$PROJ/CLAUDE.md"

  run_install

  [ "$status" -eq 0 ]
  [ "$(grep -c 'BEGIN BENCH' "$PROJ/CLAUDE.md")" -eq 1 ]
  grep -q "hash:$want" "$PROJ/CLAUDE.md"
  ! grep -q 'OLD BENCH RULES' "$PROJ/CLAUDE.md"
  grep -q 'some project rules' "$PROJ/CLAUDE.md"
  grep -q 'BEGIN BEADS INTEGRATION' "$PROJ/CLAUDE.md"
  grep -q 'beads block' "$PROJ/CLAUDE.md"
}

@test "prose that merely mentions the marker is not mistaken for the block" {
  # Regression: an unanchored /<!-- BEGIN BENCH/ match treated a documentation
  # line ABOUT the marker as the block start and deleted everything from it to
  # the END marker. This repo's own CLAUDE.md documents the marker that way.
  want="$(bash "$HASHER" "$TEMPLATE")"
  {
    printf '# My Project\n\n'
    printf -- '- **Managed block:** versioned by a content hash (`<!-- BEGIN BENCH v:N hash:XXXX -->`), managed by `/bench:init`.\n\n'
    printf '<!-- BEGIN BENCH v:1 hash:deadbeef -->\nOLD BENCH RULES\n<!-- END BENCH -->\n'
  } > "$PROJ/CLAUDE.md"

  run_install

  [ "$status" -eq 0 ]
  # The prose line survives…
  grep -q 'Managed block' "$PROJ/CLAUDE.md"
  # …and the real block — not the prose — is what got refreshed.
  [[ "$output" == *"deadbeef → $want"* ]]
  grep -q "^<!-- BEGIN BENCH v:1 hash:$want -->" "$PROJ/CLAUDE.md"
  ! grep -q 'OLD BENCH RULES' "$PROJ/CLAUDE.md"
  [ "$(grep -c '^<!-- BEGIN BENCH' "$PROJ/CLAUDE.md")" -eq 1 ]
}

@test "a CLAUDE.md with BEGIN but no END marker is left untouched" {
  printf '# Proj\n<!-- BEGIN BENCH v:1 hash:aaaa -->\nhalf a block\n' > "$PROJ/CLAUDE.md"
  before="$(cat "$PROJ/CLAUDE.md")"

  run_install

  [[ "$output" == *"no END BENCH"* ]]
  [ "$(cat "$PROJ/CLAUDE.md")" = "$before" ]
}

@test "--dry-run writes nothing at all" {
  run_install --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"would enable bench + beads"* ]]
  [[ "$output" == *"would add the orchestrator block"* ]]
  [ "$(find "$PROJ" -mindepth 1 | wc -l)" -eq 0 ]
}

@test "an existing board gets the union-merge gitattributes; no board is only reported" {
  mkdir -p "$PROJ/.beads"
  run_install
  [ "$status" -eq 0 ]
  grep -q '\*.jsonl merge=union' "$PROJ/.beads/.gitattributes"

  # Re-running does not append a second stanza. (Count the attribute line, not
  # the comment above it — the comment mentions merge=union too.)
  run_install
  [ "$(grep -c '^\*.jsonl merge=union' "$PROJ/.beads/.gitattributes")" -eq 1 ]

  rm -rf "$PROJ/.beads" "$PROJ/.claude" "$PROJ/CLAUDE.md"
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.beads" ]
  [[ "$output" == *"no .beads/ yet"* ]]
}

@test "--with installs an optional role; an unknown role warns without failing" {
  run_install --with data-eng,nope

  [ "$status" -eq 0 ]
  [ -f "$PROJ/.claude/agents/data-eng.md" ]
  [[ "$output" == *"unknown or unavailable role 'nope'"* ]]
}

@test "--with does not overwrite a role the project already customized" {
  mkdir -p "$PROJ/.claude/agents"
  echo 'my customized data-eng' > "$PROJ/.claude/agents/data-eng.md"

  run_install --with data-eng

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.claude/agents/data-eng.md")" = "my customized data-eng" ]
  [[ "$output" == *"already installed"* ]]
}

@test "the settings merge works without python3 (jq fallback)" {
  if ! command -v jq >/dev/null 2>&1; then skip "jq not installed"; fi

  # Shadow every command EXCEPT python* into a shim dir, then run with that as
  # the whole PATH, so the script's python3 branch is genuinely unavailable.
  shim="$BATS_TEST_TMPDIR/nopy"; mkdir -p "$shim"
  for d in /usr/local/bin /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      case "$b" in python*) continue ;; esac
      [ -e "$shim/$b" ] || ln -s "$f" "$shim/$b" 2>/dev/null
    done
  done
  mkdir -p "$PROJ/.claude"
  echo '{"permissions":{"allow":["Bash(ls)"]}}' > "$PROJ/.claude/settings.json"

  run env PATH="$shim" bash "$SCRIPT" --project-dir "$PROJ" --no-bd

  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled bench + beads"* ]]
  run py 'import json,sys; d=json.load(open(sys.argv[1])); print(d["permissions"]["allow"][0], len(d["enabledPlugins"]), sorted(d["extraKnownMarketplaces"]))'
  [ "$output" = "Bash(ls) 2 ['beads-marketplace', 'bench']" ]

  # …and it is idempotent on that path too.
  run env PATH="$shim" bash "$SCRIPT" --project-dir "$PROJ" --no-bd
  [ "$status" -eq 0 ]
  [[ "$output" == *"already enables"* ]]
}

@test "a fork can be installed from: BENCH_REPO steers the marketplace source" {
  run env BENCH_REPO=acme/bench-fork bash "$SCRIPT" --project-dir "$PROJ" --no-bd --no-claudemd

  [ "$status" -eq 0 ]
  run py 'import json,sys; print(json.load(open(sys.argv[1]))["extraKnownMarketplaces"]["bench"]["source"]["repo"])'
  [ "$output" = "acme/bench-fork" ]
}

@test "--help exits 0 and documents the curl one-liner" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"curl -fsSL"* ]]
  [[ "$output" == *"cloud-install.sh"* ]]
}

@test "an unknown option fails instead of silently installing" {
  run bash "$SCRIPT" --project-dir "$PROJ" --frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option"* ]]
  [ ! -e "$PROJ/.claude" ]
}
