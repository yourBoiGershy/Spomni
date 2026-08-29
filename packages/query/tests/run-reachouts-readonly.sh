#!/usr/bin/env bash
# packages/query/tests/run-reachouts-readonly.sh
#
# Wrapper for test-reachouts-readonly.mjs: golden tests for suggest_reachouts
# (attention mode / fallback mode / mixed) plus the read-only enforcement
# test proving the fixture store is never mutated by any MCP tool call.
# Same PASS/FAIL/SUMMARY conventions as packages/core/tests/*.sh.
#
# bash 3.2 portable — resolves paths relative to this script, not the
# caller's cwd, so it can be invoked from anywhere.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEST_FILE="$SCRIPT_DIR/test-reachouts-readonly.mjs"
SERVER_ENTRY="$REPO_ROOT/packages/query/server/src/index.ts"
SERVER_NODE_MODULES="$REPO_ROOT/packages/query/server/node_modules"

if [ ! -f "$TEST_FILE" ]; then
  echo "SKIP: $TEST_FILE not found — cannot run suggest_reachouts read-only tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, test file missing"
  exit 1
fi

if [ ! -f "$SERVER_ENTRY" ]; then
  echo "SKIP: $SERVER_ENTRY not found — query MCP server not built yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, server missing"
  exit 1
fi

if [ ! -d "$SERVER_NODE_MODULES" ]; then
  echo "SKIP: $SERVER_NODE_MODULES not found — run npm install in packages/query/server first."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, dependencies missing"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required but not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

node_major="$(node -e 'console.log(process.versions.node.split(".")[0])')"
if [ "$node_major" -lt 22 ] 2>/dev/null; then
  echo "SKIP: node >=22 is required for --experimental-strip-types (found $(node -v))."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, node too old"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "FAIL: git is required (used to verify the store's working-tree status) but not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

node "$TEST_FILE"
exit $?
