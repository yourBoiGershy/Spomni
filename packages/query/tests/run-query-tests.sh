#!/usr/bin/env bash
# packages/query/tests/run-query-tests.sh
#
# Runs the golden tests for the MCP query tool surface
# (packages/query/tests/test-tools.mjs) against the 30-persona fixture store
# (packages/core/fixtures/store/), and prints a PASS/FAIL/SKIP per assertion
# plus a summary line. Exits 0 only if every assertion passed; loudly SKIPs
# (still nonzero exit) if the server, its node_modules, or the fixture store
# are missing rather than staying silent.
#
# bash 3.2 portable — resolves all paths relative to this script, not the
# caller's cwd, so it can be invoked from anywhere.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEST_FILE="$SCRIPT_DIR/test-tools.mjs"
SERVER_ENTRY="$REPO_ROOT/packages/query/server/src/index.ts"
SDK_DIR="$REPO_ROOT/packages/query/server/node_modules/@modelcontextprotocol/sdk"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"

echo "--- packages/query/tests/test-tools.mjs ---"

if [ ! -f "$TEST_FILE" ]; then
  echo "SKIP: $TEST_FILE not found"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, test file missing"
  exit 1
fi

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

node "$TEST_FILE"
exit $?
