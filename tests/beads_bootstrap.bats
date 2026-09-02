#!/usr/bin/env bats
# Tests for the destructive-clear safety gate in
# plugins/bench/scripts/beads-bootstrap.sh (Bench-rm4).
#
# Invariant under test: the script may `rm -rf .beads/embeddeddolt` ONLY when
#   1. bd EXPLICITLY reported total_issues == 0, AND
#   2. a recovery source is PROVEN to exist:
#      - refs/dolt/data reachable on origin, OR
#      - a committed, non-empty .beads/issues.jsonl at HEAD.
# Every path must exit 0 (the hook must never wedge session start).
#
# Technique: each test builds a throwaway git repo fixture (with a local bare
# repo as `origin`) and puts a stub `bd` first on PATH. The stub's
# `bd stats --json` output is controlled per test via $BD_STATS_OUTPUT and
# every invocation is appended to $BD_LOG so tests can assert what ran.

SCRIPT="$BATS_TEST_DIRNAME/../plugins/bench/scripts/beads-bootstrap.sh"

setup() {
  # Isolate git from the developer's global/system config (hooks, defaults).
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  # …and from GIT_CONFIG_* env config, which a cloud container uses to inject
  # url.insteadOf rewrites: those silently rewrite an ssh fixture URL to https,
  # so a URL-form assertion would test the container, not the script.
  unset GIT_CONFIG_COUNT
  for i in 0 1 2 3 4 5 6 7 8 9; do unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"; done
  export GIT_AUTHOR_NAME="bats" GIT_AUTHOR_EMAIL="bats@test.invalid"
  export GIT_COMMITTER_NAME="bats" GIT_COMMITTER_EMAIL="bats@test.invalid"

  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$REPO"
  git -C "$REPO" remote add origin "$ORIGIN"

  # A beads project with a local engine dir containing data we must not lose.
  mkdir -p "$REPO/.beads/embeddeddolt"
  echo "precious-local-dolt-data" > "$REPO/.beads/embeddeddolt/marker"

  # A commit at HEAD (without .beads/issues.jsonl unless a test adds it).
  echo "bench" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -q -m "initial"
  git -C "$REPO" push -q origin main

  # Stub bd, first on PATH. Records every call; stats output is test-controlled.
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/bd" <<'EOF'
#!/usr/bin/env bash
echo "bd $*" >> "$BD_LOG"
case "$1 $2 $3" in
  "dolt remote list") printf '%s\n' "${BD_REMOTE_LIST-No remotes configured.}"; exit 0 ;;
  "dolt remote add")
    # The real bd also writes sync.remote into the TRACKED .beads/config.yaml.
    [ -n "${BD_CONFIG_FILE:-}" ] && printf 'sync.remote: "%s"\n' "$5" >> "$BD_CONFIG_FILE"
    exit "${BD_REMOTE_ADD_EXIT:-0}" ;;
esac
case "$1" in
  stats)     printf '%s\n' "${BD_STATS_OUTPUT-}" ;;
  bootstrap) exit "${BD_BOOTSTRAP_EXIT:-0}" ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/bd"
  export BD_LOG="$BATS_TEST_TMPDIR/bd.log"
  : > "$BD_LOG"
  export PATH="$STUB_DIR:$PATH"

  export CLAUDE_PROJECT_DIR="$REPO"
}

# Publish refs/dolt/data on the bare origin (points at main's commit; the
# gate only checks the ref exists, not its contents).
add_dolt_ref_to_origin() {
  git -C "$REPO" push -q origin main:refs/dolt/data
}

# Commit a non-empty .beads/issues.jsonl at HEAD.
commit_issues_jsonl() {
  printf '{"id":"Bench-1","title":"kept issue","status":"open"}\n' \
    > "$REPO/.beads/issues.jsonl"
  git -C "$REPO" add .beads/issues.jsonl
  git -C "$REPO" commit -q -m "export board"
  git -C "$REPO" push -q origin main
}

engine_dir_intact() {
  [ -d "$REPO/.beads/embeddeddolt" ] \
    && [ "$(cat "$REPO/.beads/embeddeddolt/marker")" = "precious-local-dolt-data" ]
}

@test "hydrated board (total_issues > 0): no clear, exits 0, engine dir untouched" {
  export BD_STATS_OUTPUT='{"total_issues": 42, "open": 7}'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already hydrated"* ]]
  engine_dir_intact
  # No rehydrate attempted on a hydrated board.
  ! grep -q "^bd bootstrap" "$BD_LOG"
}

@test "cold board (0) + refs/dolt/data on origin: engine cleared and bd bootstrap invoked" {
  export BD_STATS_OUTPUT='{"total_issues": 0}'
  add_dolt_ref_to_origin

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"recovery source present (dolt-ref)"* ]]
  [ ! -e "$REPO/.beads/embeddeddolt" ]
  grep -q "^bd bootstrap --yes" "$BD_LOG"
}

@test "cold board (0) + NO recovery source: engine NOT cleared, warning logged, exit 0" {
  export BD_STATS_OUTPUT='{"total_issues": 0}'
  # origin has main but no refs/dolt/data, and no committed issues.jsonl.

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"NO recovery source"* ]]
  [[ "$output" == *"refusing to clear"* ]]
  engine_dir_intact
}

@test "bd not on PATH: silent no-op, exit 0, engine untouched" {
  # Rebuild PATH without the stub dir (keep system dirs so git still works).
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  engine_dir_intact
  [ ! -s "$BD_LOG" ]
}

@test "bd stats unparseable (empty count): engine NOT cleared" {
  export BD_STATS_OUTPUT='error: dolt server exploded'
  add_dolt_ref_to_origin   # recovery exists, but "0" was never reported

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  engine_dir_intact
}

@test "cold board (0) + no dolt ref but committed non-empty issues.jsonl: clear proceeds (jsonl-export)" {
  export BD_STATS_OUTPUT='{"total_issues": 0}'
  commit_issues_jsonl

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"recovery source present (jsonl-export)"* ]]
  [ ! -e "$REPO/.beads/embeddeddolt" ]
  grep -q "^bd bootstrap --yes" "$BD_LOG"
}

# ── JSONL merge-conflict auto-heal (.beads/.gitattributes merge=union) ───────────

@test "auto-writes .beads/.gitattributes with merge=union when absent" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'   # hydrated: reaches the gitattributes step
  [ ! -e "$REPO/.beads/.gitattributes" ]

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q '\*\.jsonl merge=union' "$REPO/.beads/.gitattributes"
  [[ "$output" == *"wrote .beads/.gitattributes"* ]]
}

@test "gitattributes auto-heal is idempotent and preserves existing content" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  printf '# project-custom attr\n*.jsonl merge=union\n' > "$REPO/.beads/.gitattributes"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # merge=union not duplicated, and the pre-existing custom line is preserved.
  [ "$(grep -c 'merge=union' "$REPO/.beads/.gitattributes")" -eq 1 ]
  grep -q '# project-custom attr' "$REPO/.beads/.gitattributes"
  [[ "$output" != *"wrote .beads/.gitattributes"* ]]
}

@test "gitattributes step is skipped entirely when bd is not on PATH" {
  run env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ ! -e "$REPO/.beads/.gitattributes" ]   # bailed at the bd guard, before the step
}

# ── Dolt remote materialization + .beads permissions (Bench-4m0, Bench-fbc) ──────
#
# `bd dolt remote add` writes to the gitignored engine, so a fresh clone — every
# cloud container — has no remote, and `bd dolt push` then no-ops while exiting 0
# (Bench-cz6). Bootstrap must therefore re-register the remote from something that
# IS in git on every cold start, in a URL form bd accepts.

@test "cold container with no Dolt remote: registers one from the git origin, in git+ form" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote set-url origin "https://github.com/acme/widget.git"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  # git+ selects git transport; a BARE https URL is read as a DoltHub gRPC remote.
  grep -q '^bd dolt remote add origin git+https://github.com/acme/widget.git$' "$BD_LOG"
  [[ "$output" == *"registered Dolt remote"* ]]
}

@test "an https origin without .git still yields exactly one .git suffix" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote set-url origin "https://github.com/acme/widget"

  run bash "$SCRIPT"

  grep -q '^bd dolt remote add origin git+https://github.com/acme/widget.git$' "$BD_LOG"
}

@test "an ssh origin is converted to bd's git+ssh form" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote set-url origin "git@github.com:acme/widget.git"

  run bash "$SCRIPT"

  grep -q '^bd dolt remote add origin git+ssh://git@github.com/acme/widget.git$' "$BD_LOG"
}

@test "committed config.yaml sync.remote wins over the git origin" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  printf 'sync.remote: "git+ssh://git@github.com/acme/from-config.git"\n' > "$REPO/.beads/config.yaml"
  git -C "$REPO" remote set-url origin "https://github.com/acme/from-origin.git"

  run bash "$SCRIPT"

  grep -q 'remote add origin git+ssh://git@github.com/acme/from-config.git$' "$BD_LOG"
  ! grep -q 'from-origin' "$BD_LOG"
}

@test "an existing remote is never overridden" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  export BD_REMOTE_LIST='origin               git+ssh://git@github.com/acme/chosen.git'

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  ! grep -q 'remote add' "$BD_LOG"
}

@test "a tracked config.yaml rewritten by bd is restored (no dirty file, no baked-in URL)" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote set-url origin "https://github.com/acme/widget.git"
  printf '# project config\n' > "$REPO/.beads/config.yaml"
  git -C "$REPO" add .beads/config.yaml
  git -C "$REPO" commit -q -m "config"
  export BD_CONFIG_FILE="$REPO/.beads/config.yaml"   # stub bd appends sync.remote

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/.beads/config.yaml")" = "# project config" ]
  git -C "$REPO" diff --quiet -- .beads/config.yaml
  [[ "$output" == *"restored tracked .beads/config.yaml"* ]]
}

@test "an UNtracked config.yaml is left as bd wrote it" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote set-url origin "https://github.com/acme/widget.git"
  printf '# scratch config\n' > "$REPO/.beads/config.yaml"   # not committed
  export BD_CONFIG_FILE="$REPO/.beads/config.yaml"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  grep -q 'sync.remote' "$REPO/.beads/config.yaml"
  [[ "$output" != *"restored tracked"* ]]
}

@test "no git origin and no config: nothing is registered, exit 0" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  git -C "$REPO" remote remove origin

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  ! grep -q 'remote add' "$BD_LOG"
}

@test ".beads is tightened to 0700 (bd warns on every call otherwise)" {
  export BD_STATS_OUTPUT='{"total_issues": 5}'
  chmod 755 "$REPO/.beads"

  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$REPO/.beads" 2>/dev/null || stat -f %Lp "$REPO/.beads")" = "700" ]
}
