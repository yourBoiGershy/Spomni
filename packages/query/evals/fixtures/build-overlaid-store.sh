#!/bin/bash
# build-overlaid-store.sh — materializes the fixture store the
# opt-out-respected/ and stated-outranks-revealed/ T2 cases run against.
#
# eval-case.md's `store` frontmatter field is a single repo-relative path;
# it has no "overlay" field, and eval-run.sh (deliberately not modified by
# this package) only ever copies one directory. So the combined store these
# two cases need — the 30-persona base store
# (packages/core/fixtures/store) plus the plan-11 personalization overlay
# (packages/query/tests/fixtures/personalization-overlay) — is built ONCE by
# this script into a fixed, gitignored location under packages/query/evals/
# fixtures/, and the cases' prompt.md `store:` field points at that fixed
# path. Re-run this script any time either source fixture changes; it is
# idempotent (always rebuilds from scratch).
#
# Usage: build-overlaid-store.sh [output-dir]
#   output-dir defaults to packages/query/evals/fixtures/overlaid-store
#   (relative to the repo root), which is what the two cases' prompt.md
#   files reference. Prints the resulting absolute path on stdout.
#
# Portable to bash 3.2 (macOS default).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

BASE_STORE="$REPO_ROOT/packages/core/fixtures/store"
OVERLAY_DIR="$REPO_ROOT/packages/query/tests/fixtures/personalization-overlay"
OUT_DIR_ARG="${1:-packages/query/evals/fixtures/overlaid-store}"

case "$OUT_DIR_ARG" in
  /*) OUT_DIR="$OUT_DIR_ARG" ;;
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR_ARG" ;;
esac

if [ ! -d "$BASE_STORE" ]; then
  echo "build-overlaid-store.sh: base store not found: $BASE_STORE" >&2
  exit 1
fi

if [ ! -d "$OVERLAY_DIR" ]; then
  echo "build-overlaid-store.sh: overlay fixture not found: $OVERLAY_DIR" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

cp -R "$BASE_STORE"/. "$OUT_DIR"/
cp "$OVERLAY_DIR/profile.md" "$OUT_DIR"/
cp "$OVERLAY_DIR/ranking-weights.json" "$OUT_DIR"/
mkdir -p "$OUT_DIR/wakeups"
cp -R "$OVERLAY_DIR/wakeups"/. "$OUT_DIR/wakeups"/

if [ -x "$REPO_ROOT/packages/core/scripts/validate-store.sh" ]; then
  if ! bash "$REPO_ROOT/packages/core/scripts/validate-store.sh" "$OUT_DIR" >&2; then
    echo "build-overlaid-store.sh: overlaid store failed validate-store.sh" >&2
    exit 1
  fi
fi

echo "$OUT_DIR"
