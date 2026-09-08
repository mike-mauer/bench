#!/usr/bin/env bash
# scripts/tdd-order-check.sh — verify TDD-from-history on a commit range.
#
# Bench v2 requires the red test to be its own commit before any production
# change (docs/factory-protocol.md §7). This script is the machine check: it
# walks the given commit range oldest -> newest and fails the first time a
# "production" commit appears without a preceding "test-only" commit in the
# same range.
#
# A commit is classified by the files it touches, after dropping doc files
# (*.md, anything under docs/) from consideration entirely:
#   - test-only  : every remaining file matches a test-file pattern
#                  (tests?/, __tests__/, spec/, *.test.*, *.spec.*, *_test.go,
#                  test_*.py, *.bats)
#   - production : at least one remaining file does not match a test pattern
#   - (docs-only): no remaining files — skipped, doesn't affect ordering
#
# Merge commits are skipped. Usage:
#   tdd-order-check.sh <base>..<head>
#   tdd-order-check.sh <base> <head>
set -uo pipefail

log() { printf '[tdd-order-check] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: tdd-order-check.sh <base>..<head>
       tdd-order-check.sh <base> <head>

Walks non-merge commits oldest to newest in the range. A "test-only" commit
touches only test files (tests?/, __tests__/, spec/, *.test.*, *.spec.*,
*_test.go, test_*.py, *.bats) once doc files (*.md, docs/) are ignored. A
commit that touches any other file is a "production" commit. Fails (exit 1)
if the first production commit in the range has no preceding test-only
commit earlier in the same range. Merge commits are skipped.

Options:
  -h, --help   show this help and exit
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

if [ "$#" -eq 1 ]; then
  range="$1"
  case "$range" in
    *..*) ;;
    *)
      log "single-argument form needs a <base>..<head> range, got: $range"
      usage >&2
      exit 2
      ;;
  esac
elif [ "$#" -eq 2 ]; then
  range="$1..$2"
else
  usage >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  log "git not found on PATH"
  exit 2
fi

is_test_path() {
  path="$1"
  base="${path##*/}"
  case "$path" in
    test/*|*/test/*|tests/*|*/tests/*) return 0 ;;
    __tests__/*|*/__tests__/*) return 0 ;;
    spec/*|*/spec/*) return 0 ;;
  esac
  case "$base" in
    *.test.*|*.spec.*|*_test.go|test_*.py|*.bats) return 0 ;;
  esac
  return 1
}

is_doc_path() {
  path="$1"
  case "$path" in
    *.md) return 0 ;;
    docs/*|*/docs/*) return 0 ;;
  esac
  return 1
}

commits="$(git rev-list --no-merges --reverse "$range" 2>&1)" || {
  log "git rev-list failed for range '$range': $commits"
  exit 2
}

seen_test_only=0

while IFS= read -r commit; do
  [ -n "$commit" ] || continue

  files="$(git diff-tree --no-commit-id --name-only -r --root "$commit")"

  has_prod=0
  has_nondoc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_doc_path "$f" && continue
    has_nondoc=1
    if ! is_test_path "$f"; then
      has_prod=1
    fi
  done <<< "$files"

  [ "$has_nondoc" -eq 1 ] || continue  # docs-only commit: skip, doesn't affect ordering

  if [ "$has_prod" -eq 1 ]; then
    if [ "$seen_test_only" -eq 0 ]; then
      subject="$(git log -1 --format=%s "$commit")"
      log "FAIL: production commit ${commit} (\"${subject}\") has no preceding test-only commit in range ${range}"
      exit 1
    fi
  else
    seen_test_only=1
  fi
done <<< "$commits"

log "PASS: TDD order holds for range ${range}"
exit 0
