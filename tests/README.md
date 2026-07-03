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

CI runs the same suite plus shellcheck (`--severity=warning`) and
`claude plugin validate --strict` — see `.github/workflows/ci.yml`.
