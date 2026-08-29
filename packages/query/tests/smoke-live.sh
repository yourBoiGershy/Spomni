#!/usr/bin/env bash
# packages/query/tests/smoke-live.sh
#
# Live-store smoke for the query MCP server: drives the built server
# (packages/query/server/src/index.ts) over stdio JSON-RPC against a real
# store dir (smoke-live.mjs) and exercises all six read-only tools
# data-independently, printing per-tool PASS/FAIL and exiting nonzero on any
# failure — "the server works against the live store" as one command.
#
# Usage: smoke-live.sh [store-dir]
#   store-dir defaults to <repo-root>/data/store.
#
# bash 3.2 portable — resolves all paths relative to this script, not the
# caller's cwd, matching run-query-tests.sh's conventions.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STORE_DIR="${1:-$REPO_ROOT/data/store}"

SERVER_ENTRY="$REPO_ROOT/packages/query/server/src/index.ts"
SDK_DIR="$REPO_ROOT/packages/query/server/node_modules/@modelcontextprotocol/sdk"
SMOKE_MJS="$SCRIPT_DIR/smoke-live.mjs"

if [ ! -f "$SERVER_ENTRY" ]; then
  echo "FAIL smoke: query MCP server entry point not found at $SERVER_ENTRY"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, server missing"
  exit 1
fi

if [ ! -d "$SDK_DIR" ]; then
  echo "FAIL smoke: @modelcontextprotocol/sdk not installed at $SDK_DIR"
  echo "      run: (cd packages/query/server && npm install)"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, sdk missing"
  exit 1
fi

if [ ! -d "$STORE_DIR" ]; then
  echo "FAIL smoke: store dir not found at $STORE_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, store missing"
  exit 1
fi

if [ ! -f "$SMOKE_MJS" ]; then
  echo "FAIL smoke: $SMOKE_MJS not found"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, smoke script missing"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL smoke: node not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, node missing"
  exit 1
fi

node --experimental-strip-types "$SMOKE_MJS" --store "$STORE_DIR"
exit $?
