#!/usr/bin/env bash
# packages/query/tests/run-query-tests.sh
#
# Runs the golden tests for the MCP query tool surface
# (packages/query/tests/test-tools.mjs) against the 31-persona fixture store
# (packages/core/fixtures/store/), plus the personalization-overlay goldens
# (packages/query/tests/test-personalization.mjs) and the upcoming_meetings
# tool tests (packages/query/tests/test-upcoming-meetings.mjs), and prints a
# PASS/FAIL/XFAIL/XPASS/SKIP per assertion plus a summary line per test file.
# Exits 0 only if every test file exited 0; loudly SKIPs (still nonzero exit)
# if the server, its node_modules, or the fixture store are missing rather
# than staying silent.
#
# bash 3.2 portable — resolves all paths relative to this script, not the
# caller's cwd, so it can be invoked from anywhere.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SERVER_ENTRY="$REPO_ROOT/packages/query/server/src/index.ts"
SDK_DIR="$REPO_ROOT/packages/query/server/node_modules/@modelcontextprotocol/sdk"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"

if [ ! -f "$SERVER_ENTRY" ]; then
  echo "SKIP: query MCP server entry point not found at $SERVER_ENTRY"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, server missing"
  exit 1
fi

if [ ! -d "$SDK_DIR" ]; then
  echo "SKIP: @modelcontextprotocol/sdk not installed at $SDK_DIR"
  echo "      run: (cd packages/query/server && npm install)"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, sdk missing"
  exit 1
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  echo "SKIP: fixture store not found at $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, fixture store missing"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, node missing"
  exit 1
fi

overall_status=0

for TEST_FILE in "$SCRIPT_DIR/test-tools.mjs" "$SCRIPT_DIR/test-personalization.mjs" "$SCRIPT_DIR/test-upcoming-meetings.mjs"; do
  echo "--- $TEST_FILE ---"

  if [ ! -f "$TEST_FILE" ]; then
    echo "SKIP: $TEST_FILE not found"
    echo ""
    echo "SUMMARY: 0 passed, 0 failed, test file missing"
    overall_status=1
    continue
  fi

  node "$TEST_FILE"
  status=$?
  if [ "$status" -ne 0 ]; then
    overall_status=$status
  fi
  echo ""
done

exit $overall_status
