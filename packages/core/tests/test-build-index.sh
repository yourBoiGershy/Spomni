#!/usr/bin/env bash
# packages/core/tests/test-build-index.sh
#
# Golden test for packages/core/scripts/build-index.sh (plan 38 unit B1 —
# the single-awk-pass rewrite). Locks two things:
#
#   1. Byte-identical output. index.json for
#      packages/core/fixtures/store/ and
#      packages/query/tests/fixtures/who-next-direct/store/ must `cmp`
#      exactly against the committed goldens under
#      packages/core/tests/goldens/index/ — those goldens were captured
#      from the PRE-REWRITE (per-person jq/sed/awk pipeline) version of
#      build-index.sh, not read off the new script's own output, per
#      docs/DECISIONS.md's golden-tests-before-prompts rule.
#   2. O(1) process spawns. Under `bash -x`, the number of xtrace lines
#      invoking `jq ` must be <= 3 — proof the rewrite doesn't spawn a
#      jq/sed/awk process per person.
#
# Also asserts the zero-people case still yields `{}`.
#
# bash 3.2 portable (no associative arrays, no mapfile) + jq.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BUILD_INDEX="$REPO_ROOT/packages/core/scripts/build-index.sh"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"
WHO_NEXT_STORE="$REPO_ROOT/packages/query/tests/fixtures/who-next-direct/store"
GOLDEN_DIR="$REPO_ROOT/packages/core/tests/goldens/index"
GOLDEN_FIXTURE="$GOLDEN_DIR/fixture-store.index.json"
GOLDEN_WHO_NEXT="$GOLDEN_DIR/who-next-direct-store.index.json"

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

summary_and_exit() {
  echo ""
  echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
  else
    exit 1
  fi
}

# --- build-index.sh must exist ---
if [ ! -f "$BUILD_INDEX" ]; then
  echo "SKIP: $BUILD_INDEX not found — cannot run build-index golden test yet."
  fail "build-index.sh missing at $BUILD_INDEX"
  summary_and_exit
fi

if [ ! -x "$BUILD_INDEX" ]; then
  fail "$BUILD_INDEX exists but is not executable"
  summary_and_exit
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found on PATH"
  summary_and_exit
fi

for req in "$FIXTURE_STORE" "$WHO_NEXT_STORE" "$GOLDEN_FIXTURE" "$GOLDEN_WHO_NEXT"; do
  if [ ! -e "$req" ]; then
    fail "required fixture/golden missing: $req"
    summary_and_exit
  fi
done

# --- run against temp copies of each store; never write into a committed
#     fixture dir. ---
TMP_STORE_1="$(mktemp -d 2>/dev/null || mktemp -d -t 'build-index-test')"
TMP_STORE_2="$(mktemp -d 2>/dev/null || mktemp -d -t 'build-index-test')"
TMP_STORE_ZERO="$(mktemp -d 2>/dev/null || mktemp -d -t 'build-index-test')"

cleanup() {
  rm -rf "$TMP_STORE_1" "$TMP_STORE_2" "$TMP_STORE_ZERO"
}
trap cleanup EXIT

cp -R "$FIXTURE_STORE/." "$TMP_STORE_1/"
cp -R "$WHO_NEXT_STORE/." "$TMP_STORE_2/"
mkdir -p "$TMP_STORE_ZERO/people"

# =====================================================================
# (a) byte-identical output vs. the goldens
# =====================================================================

run1_output="$("$BUILD_INDEX" "$TMP_STORE_1" 2>&1)"
run1_status=$?
if [ "$run1_status" -eq 0 ]; then
  pass "build-index.sh exits 0 against the fixture store"
else
  fail "build-index.sh exited $run1_status (expected 0) against the fixture store: $run1_output"
fi

if [ -f "$TMP_STORE_1/index.json" ] && cmp -s "$TMP_STORE_1/index.json" "$GOLDEN_FIXTURE"; then
  pass "fixture-store index.json is byte-identical to the golden"
else
  fail "fixture-store index.json differs from the golden ($GOLDEN_FIXTURE)"
  diff "$TMP_STORE_1/index.json" "$GOLDEN_FIXTURE" 2>&1 | head -40
fi

run2_output="$("$BUILD_INDEX" "$TMP_STORE_2" 2>&1)"
run2_status=$?
if [ "$run2_status" -eq 0 ]; then
  pass "build-index.sh exits 0 against the who-next-direct fixture store"
else
  fail "build-index.sh exited $run2_status (expected 0) against the who-next-direct fixture store: $run2_output"
fi

if [ -f "$TMP_STORE_2/index.json" ] && cmp -s "$TMP_STORE_2/index.json" "$GOLDEN_WHO_NEXT"; then
  pass "who-next-direct-store index.json is byte-identical to the golden"
else
  fail "who-next-direct-store index.json differs from the golden ($GOLDEN_WHO_NEXT)"
  diff "$TMP_STORE_2/index.json" "$GOLDEN_WHO_NEXT" 2>&1 | head -40
fi

# =====================================================================
# (b) zero-people case yields {}
# =====================================================================

run_zero_output="$("$BUILD_INDEX" "$TMP_STORE_ZERO" 2>&1)"
run_zero_status=$?
if [ "$run_zero_status" -eq 0 ] && [ -f "$TMP_STORE_ZERO/index.json" ] && [ "$(cat "$TMP_STORE_ZERO/index.json")" = "{}" ]; then
  pass "zero-people store yields index.json == {}"
else
  fail "zero-people store did not yield {} (exit $run_zero_status): $run_zero_output"
fi

# =====================================================================
# (c) O(1) process spawns: under `bash -x`, at most 3 xtrace lines
#     invoke jq — proof the rewrite doesn't spawn a process per person.
# =====================================================================

XTRACE_LOG="$(mktemp 2>/dev/null || mktemp -t 'build-index-xtrace')"
bash -x "$BUILD_INDEX" "$TMP_STORE_1" > "$XTRACE_LOG" 2>&1
jq_line_count="$(grep -c '^+.*jq ' "$XTRACE_LOG")"
if [ "$jq_line_count" -le 3 ]; then
  pass "build-index.sh spawns at most 3 jq processes ($jq_line_count observed) — O(1), not O(people)"
else
  fail "build-index.sh spawned $jq_line_count jq processes (expected <= 3) — process count scales with people, not O(1)"
fi
rm -f "$XTRACE_LOG"

# --- committed fixture dirs must not have gained an index.json ---
if [ -f "$FIXTURE_STORE/index.json" ]; then
  fail "packages/core/fixtures/store/index.json exists — the fixture dir must stay pristine (test must run against a temp copy)"
else
  pass "committed fixture store has no index.json (test ran against a temp copy, as required)"
fi

if [ -f "$WHO_NEXT_STORE/index.json" ]; then
  fail "packages/query/tests/fixtures/who-next-direct/store/index.json exists — the fixture dir must stay pristine (test must run against a temp copy)"
else
  pass "committed who-next-direct fixture store has no index.json (test ran against a temp copy, as required)"
fi

summary_and_exit
