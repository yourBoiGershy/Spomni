#!/usr/bin/env bash
# packages/query/tests/run-bench-smoke-tests.sh
#
# Smoke test for packages/query/tests/bench-retrieval.sh: runs it on
# packages/core/fixtures/store with --json --runs 1, asserts the JSON parses
# with jq and has >=5 rows, and that the fixture store's files are
# unchanged (checksum before/after — bench-retrieval.sh must never write
# into the given store). Same style as
# packages/ingestion/tests/run-structured-tests.sh: numbered assertions via
# pass()/fail(), a SUMMARY line, non-zero exit on any failure. bash 3.2
# portable (no associative arrays, no mapfile). Needs jq.
#
# Not wired into scripts/test-all.sh yet (plan 38 wave 3 does that once the
# 127-row thresholds exist).

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BENCH="${SCRIPT_DIR}/bench-retrieval.sh"
FIXTURE_STORE="${REPO_ROOT}/packages/core/fixtures/store"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

if [ ! -d "$FIXTURE_STORE/people" ]; then
  echo "FAIL: fixture store missing at $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$BENCH" ]; then
  echo "FAIL: $BENCH is missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  echo "FAIL: jq is required"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
}

# Checksum the fixture store before running (find + md5/shasum over paths+
# mtimes+content, portable across BSD/GNU).
checksum_store() {
  find "$1" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 cksum 2>/dev/null
}

BEFORE="$(checksum_store "$FIXTURE_STORE")"

BENCH_OUT="$(bash "$BENCH" "$FIXTURE_STORE" --json --runs 1 2>/tmp/bench-smoke-err.$$)"
BENCH_STATUS=$?
if [ "$BENCH_STATUS" -eq 0 ]; then
  pass "bench-retrieval.sh --json --runs 1 exits 0"
else
  fail "bench-retrieval.sh --json --runs 1 exits 0 (got $BENCH_STATUS)"
  cat /tmp/bench-smoke-err.$$ >&2
fi
rm -f /tmp/bench-smoke-err.$$

if echo "$BENCH_OUT" | jq -e . >/dev/null 2>&1; then
  pass "output is valid JSON"
else
  fail "output is valid JSON"
fi

ROW_COUNT="$(echo "$BENCH_OUT" | jq '.rows | length' 2>/dev/null || echo 0)"
if [ "$ROW_COUNT" -ge 5 ]; then
  pass "rows array has >=5 entries (got $ROW_COUNT)"
else
  fail "rows array has >=5 entries (got $ROW_COUNT)"
fi

AFTER="$(checksum_store "$FIXTURE_STORE")"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "fixture store files unchanged (checksum match)"
else
  fail "fixture store files unchanged (checksum match) — bench-retrieval.sh wrote into the given store!"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
