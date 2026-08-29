#!/usr/bin/env bash
# packages/core/tests/run-store-tests.sh
#
# Asserts that packages/core/scripts/validate-store.sh:
#   1. passes (exit 0) against the clean fixture store
#      (packages/core/fixtures/store/)
#   2. fails (exit 1) against the seeded-corruption fixture store
#      (packages/core/fixtures/corrupted/) and reports every one of the 5
#      seeded corruptions (matched by the filename of the corrupted file).
#
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
CLEAN_STORE="$REPO_ROOT/packages/core/fixtures/store"
CORRUPTED_STORE="$REPO_ROOT/packages/core/fixtures/corrupted"

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

# --- validator must exist ---
if [ ! -f "$VALIDATOR" ]; then
  echo "SKIP: $VALIDATOR not found — cannot run store tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, validator missing"
  exit 1
fi

if [ ! -x "$VALIDATOR" ]; then
  echo "FAIL: $VALIDATOR exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# --- assertion 1: clean store passes ---
if [ ! -d "$CLEAN_STORE" ]; then
  fail "clean fixture store missing at $CLEAN_STORE"
else
  clean_output="$("$VALIDATOR" "$CLEAN_STORE" 2>&1)"
  clean_status=$?
  if [ "$clean_status" -eq 0 ]; then
    pass "validate-store.sh exits 0 on the clean fixture store"
  else
    fail "validate-store.sh exited $clean_status (expected 0) on the clean fixture store"
    echo "$clean_output"
  fi
fi

# --- assertion 2: corrupted store fails ---
if [ ! -d "$CORRUPTED_STORE" ]; then
  fail "corrupted fixture store missing at $CORRUPTED_STORE"
  corrupted_output=""
  corrupted_status=""
else
  corrupted_output="$("$VALIDATOR" "$CORRUPTED_STORE" 2>&1)"
  corrupted_status=$?
  if [ "$corrupted_status" -eq 1 ]; then
    pass "validate-store.sh exits 1 on the corrupted fixture store"
  else
    fail "validate-store.sh exited $corrupted_status (expected 1) on the corrupted fixture store"
  fi
fi

# --- assertion 3: every seeded corruption is reported, by filename ---
# One entry per seeded corruption (see fixtures/corrupted/README.md).
# The duplicate-slug corruption spans two files; both must be mentioned.
seeded_files="
2026-08-15-priya-nandakumar.md:broken link to a nonexistent person
jordan-abernathy.md:malformed frontmatter (missing closing ---)
2026-08-10-orphan.md:orphan interaction with no linked people
leo-fenwick.md:duplicate person slug (leo-fenwick)
leo-fenwick-duplicate.md:duplicate person slug (leo-fenwick)
2026-09-05-priya-nandakumar.md:invalid wakeup status
"

if [ -n "${corrupted_output:-}" ]; then
  # `<<<` (here-string) runs the loop in the current shell under bash 3.2
  # (unlike piping into `while`, which forks a subshell), so PASS_COUNT/
  # FAIL_COUNT updates inside the loop are visible afterward.
  while IFS=':' read -r fname desc; do
    [ -z "$fname" ] && continue
    if printf '%s' "$corrupted_output" | grep -qF -- "$fname"; then
      pass "output mentions $fname ($desc)"
    else
      fail "output does not mention $fname ($desc)"
    fi
  done <<< "$seeded_files"
else
  fail "no output captured from validate-store.sh against the corrupted store — cannot check seeded corruptions"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

STORE_TESTS_STATUS=0
if [ "$FAIL_COUNT" -ne 0 ]; then
  STORE_TESTS_STATUS=1
fi

# --- delegate to the build-stats.sh golden test, tallying its exit status
#     alongside this script's own ---
BUILD_STATS_TEST="$SCRIPT_DIR/test-build-stats.sh"
echo ""
echo "--- test-build-stats.sh ---"
if [ -x "$BUILD_STATS_TEST" ]; then
  "$BUILD_STATS_TEST"
  build_stats_status=$?
  if [ "$build_stats_status" -ne 0 ]; then
    STORE_TESTS_STATUS=1
  fi
else
  echo "FAIL: $BUILD_STATS_TEST not found or not executable"
  STORE_TESTS_STATUS=1
fi

exit "$STORE_TESTS_STATUS"
