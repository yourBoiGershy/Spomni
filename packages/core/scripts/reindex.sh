#!/bin/bash
# reindex.sh — the one call every store writer makes after touching
# people/ or interactions/.
#
# Usage: reindex.sh <store-dir> [--quiet]
#
# Runs build-index.sh then build-stats.sh against <store-dir>, in that
# order, so index.json and stats.json are always fresh together at filing
# time and readers never have to rebuild (plan 38 unit D1). Idempotent —
# safe to call after every write, even ones that didn't touch people/ or
# interactions/.
#
# --quiet suppresses the two scripts' stdout ("indexed N people → ..." /
# "stats for N people → ..."); their stderr always passes through, and
# non-quiet mode prints exactly one summary line instead of forwarding
# theirs.
#
# Exit code is the first failure's exit code (build-index.sh's, if it
# fails; otherwise build-stats.sh's). Writes nothing itself except by
# delegating to the two sibling scripts — never touches people/ or
# interactions/ mtimes.
#
# Portable to bash 3.2 (macOS default).

set -eu

usage() {
  echo "Usage: reindex.sh <store-dir> [--quiet]"
  echo ""
  echo "Runs build-index.sh then build-stats.sh against <store-dir>, so"
  echo "index.json and stats.json are always fresh together after any write"
  echo "to people/ or interactions/. --quiet suppresses their stdout."
}

if [ $# -eq 0 ]; then
  usage
  exit 0
fi

STORE_DIR=""
QUIET=0

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --quiet)
      QUIET=1
      ;;
    *)
      STORE_DIR="$arg"
      ;;
  esac
done

if [ -z "$STORE_DIR" ]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_INDEX="$SCRIPT_DIR/build-index.sh"
BUILD_STATS="$SCRIPT_DIR/build-stats.sh"

if [ "$QUIET" -eq 1 ]; then
  "$BUILD_INDEX" "$STORE_DIR" >/dev/null
  "$BUILD_STATS" "$STORE_DIR" >/dev/null
else
  "$BUILD_INDEX" "$STORE_DIR" >/dev/null
  "$BUILD_STATS" "$STORE_DIR" >/dev/null
  echo "reindexed ${STORE_DIR}: index.json + stats.json"
fi
