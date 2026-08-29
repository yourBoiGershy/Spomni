#!/bin/bash
# run-perf.sh — thin runner for perf-harness.mjs (packages/query/tests/),
# per docs/plans/2026-08-29-08-chat-mcp-query-layer.md "Performance envelope".
#
# Usage: packages/query/tests/run-perf.sh
#
# Requires the query server's node_modules to be installed
# (packages/query/server/) and Node >= 22.6 on PATH. Exits 0 only if every
# performance target is met.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="${SCRIPT_DIR}/../server"

if [ ! -d "${SERVER_DIR}/node_modules" ]; then
  echo "run-perf.sh: ${SERVER_DIR}/node_modules missing — run 'npm install' in packages/query/server/ first" >&2
  exit 1
fi

exec node --experimental-strip-types "${SCRIPT_DIR}/perf-harness.mjs"
