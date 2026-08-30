#!/usr/bin/env bash
# packages/query/tests/run-bench-guard.sh
#
# Regression guard for packages/query/tests/bench-retrieval.sh, per plan 38
# unit H: runs `bench-retrieval.sh packages/core/fixtures/store --runs 1
# --guard`, which times every §1 row on a scratch copy of the fixture store
# and compares each against the plan's fixture-store (30-person, x3 CI
# headroom) thresholds, plus a deterministic jq-spawn-count check on
# build-index.sh / who-next-direct.sh. Exits non-zero on any GUARD FAIL
# line (bench-retrieval.sh's own exit code).
#
# SKIPs with exit 0 (same idiom as run-query-tests.sh's missing-dependency
# messages, but exit 0 here — this suite is timing-only, not a functional
# regression, so a missing node toolchain on a checkout without `npm ci`
# should not fail CI) when the query server's node_modules or node itself
# are absent — the MCP cold-start/warm-tool rows are then skipped inside
# bench-retrieval.sh itself and only the non-node rows are guarded.
#
# bash 3.2 portable — resolves all paths relative to this script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
BENCH="${SCRIPT_DIR}/bench-retrieval.sh"
FIXTURE_STORE="${REPO_ROOT}/packages/core/fixtures/store"
SERVER_DIR="${REPO_ROOT}/packages/query/server"

if [ ! -f "$BENCH" ]; then
  echo "SKIP: bench-retrieval.sh not found at $BENCH"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, harness missing"
  exit 0
fi

if [ ! -d "$FIXTURE_STORE/people" ]; then
  echo "SKIP: fixture store not found at $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, fixture store missing"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, jq missing"
  exit 0
fi

if [ ! -d "${SERVER_DIR}/node_modules" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP: query MCP server node_modules or node not present — running guard without MCP rows"
fi

echo "=== bench-retrieval.sh $FIXTURE_STORE --runs 1 --guard ==="
bash "$BENCH" "$FIXTURE_STORE" --runs 1 --guard
STATUS=$?

echo ""
if [ "$STATUS" -eq 0 ]; then
  echo "SUMMARY: 1 passed, 0 failed"
else
  echo "SUMMARY: 0 passed, 1 failed"
fi
exit "$STATUS"
