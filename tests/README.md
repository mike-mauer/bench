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

- `beads_bootstrap.bats` — the destructive-clear safety gate in
  `plugins/bench/scripts/beads-bootstrap.sh` (Bench-rm4): the local Dolt
  engine dir may only be removed when bd explicitly reported an empty board
  AND a recovery source (origin `refs/dolt/data`, or a committed non-empty
  `.beads/issues.jsonl` at HEAD) is proven to exist. Each test builds a
  throwaway git repo fixture with a local bare `origin` and a stub `bd` on
  PATH whose `stats --json` output is controlled per test.

- `cloud_install.bats` — `plugins/bench/scripts/cloud-install.sh`, the curl-able
  cloud installer: the `.claude/settings.json` merge (adds the marketplace +
  `enabledPlugins` entries, preserves unrelated keys, never duplicates on a
  re-run, works on both the python3 and jq paths), the `CLAUDE.md` block
  injection/refresh — including that its marker hash matches the canonical
  `bench-hash.sh`, since a mismatch would make every session warn "stale" — and
  the refuse-don't-clobber paths (object-shaped `enabledPlugins`, unbalanced
  BENCH markers), plus `--dry-run` writing nothing. Hermetic: every test runs
  the script against the local checkout with `--no-bd`, so nothing is fetched.

- `claudemd_drift_check.bats` — `plugins/bench/scripts/claudemd-drift-check.sh`:
  stale/current/absent block reporting, that the hook never edits `CLAUDE.md`,
  and the marker-anchoring regression — a file that merely *mentions*
  `<!-- BEGIN BENCH ... -->` in prose used to yield an empty hash, silencing the
  staleness warning entirely.

CI runs the same suite plus shellcheck (`--severity=warning`) and
`claude plugin validate --strict` — see `.github/workflows/ci.yml`.
