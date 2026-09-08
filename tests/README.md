# Tests

Bats tests for the bench plugin's shell hook scripts.

## Run locally

```bash
# install bats-core if missing
brew install bats-core        # macOS
# or: npm install -g bats

bats tests/
```

## What is covered

- `cloud_install.bats` — `plugins/bench/scripts/cloud-install.sh`, the curl-able
  cloud installer: the `.claude/settings.json` merge (adds the marketplace +
  `enabledPlugins` entries, preserves unrelated keys, never duplicates on a
  re-run, works on both the python3 and jq paths), the `CLAUDE.md` block
  injection/refresh — including that its marker hash matches the canonical
  `bench-hash.sh`, since a mismatch would make every session warn "stale" — and
  the refuse-don't-clobber paths (object-shaped `enabledPlugins`, unbalanced
  BENCH markers), plus `--dry-run` writing nothing. Hermetic: every test runs
  the script against the local checkout with `BENCH_SOURCE_DIR` pointed at this
  checkout, so nothing is fetched.

- `claudemd_drift_check.bats` — `plugins/bench/scripts/claudemd-drift-check.sh`:
  stale/current/absent block reporting, that the hook never edits `CLAUDE.md`,
  and the marker-anchoring regression — a file that merely *mentions*
  `<!-- BEGIN BENCH ... -->` in prose used to yield an empty hash, silencing the
  staleness warning entirely.

- `human_todos.bats` — `plugins/bench/scripts/human-todos.sh`, the SessionStart
  hook that lists the current user's open `human:todo` issues
  (docs/factory-protocol.md §15): silent when `gh` is missing, unauthenticated,
  or there are zero to-dos; two to-dos print two lines with the `## Blocks`
  ref parsed into a `(blocks #n)` suffix; a body with no `## Blocks` section
  omits the suffix. `gh` is stubbed on `PATH` via a fixture script written
  into `$BATS_TEST_TMPDIR` per test — no real GitHub CLI or network involved.

- `tdd_order_check.bats` — `plugins/bench/scripts/tdd-order-check.sh`, the
  TDD-from-history check (docs/factory-protocol.md §7): test-then-impl passes,
  impl-then-test and impl-only fail naming the offending commit, docs-only and
  test-only ranges pass, a merge commit is skipped (the check still fires on
  the untested production commit merged in), and a squashed commit that adds
  both a test and production code in one commit fails. Each test builds a
  throwaway git repo under `$BATS_TEST_TMPDIR` and runs the script against a
  real commit range.

CI runs the same suite plus shellcheck (`--severity=warning`) and
`claude plugin validate --strict` — see `.github/workflows/ci.yml`.
