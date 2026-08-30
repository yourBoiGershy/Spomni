#!/bin/bash
# file-out.sh — always-on outbox audit adapter.
#
# Usage:
#   file-out.sh <store-dir> --text-file <f> --batch <batch-path> [--today <YYYY-MM-DD>]
#
# Appends the rendered nudge-card text to <store-dir>/outbox/<today>.md
# under a section header named after the batch file, and prints the
# outbox file's path. Creates outbox/ if absent.
#
# This script is not idempotent by itself — a rerun with the same
# --batch appends a second section. Idempotency (never re-delivering the
# same fired batch twice) is deliver-tick.sh's job via delivered.log, not
# this script's.
#
# Exit 0 on success (prints "outbox: <path>" to stdout).
# Exit 2 on usage error or missing --text-file.
#
# Portable to bash 3.2 (macOS default).

set -u

STORE_DIR="${1:-}"
if [ -z "$STORE_DIR" ]; then
  echo "file-out.sh: <store-dir> is required" >&2
  exit 2
fi
shift

TEXT_FILE=""
BATCH_PATH=""
TODAY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --text-file)
      TEXT_FILE="${2:-}"
      shift 2
      ;;
    --batch)
      BATCH_PATH="${2:-}"
      shift 2
      ;;
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    *)
      echo "file-out.sh: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$TEXT_FILE" ] || [ -z "$BATCH_PATH" ]; then
  echo "file-out.sh: --text-file and --batch are required" >&2
  exit 2
fi

if [ ! -f "$TEXT_FILE" ]; then
  echo "file-out.sh: --text-file not found: $TEXT_FILE" >&2
  exit 2
fi

if [ -z "$TODAY" ]; then
  TODAY="$(date -u +%Y-%m-%d)"
fi

OUTBOX_DIR="$STORE_DIR/outbox"
mkdir -p "$OUTBOX_DIR"

OUTBOX_FILE="$OUTBOX_DIR/$TODAY.md"
BATCH_NAME="$(basename "$BATCH_PATH")"

{
  echo "## $BATCH_NAME"
  echo ""
  cat "$TEXT_FILE"
  echo ""
} >> "$OUTBOX_FILE"

echo "outbox: $OUTBOX_FILE"
exit 0
