#!/usr/bin/env bash
# packages/core/tests/test-demo-store.sh
#
# Asserts that packages/core/scripts/demo-store.sh produces a valid,
# self-describing synthetic demo store, and correctly refuses to clobber a
# non-empty destination without --force.
#
# bash 3.2 portable (no associative arrays, no mapfile).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DEMO_STORE="$REPO_ROOT/packages/core/scripts/demo-store.sh"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"

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

if [ ! -f "$DEMO_STORE" ]; then
  fail "demo-store.sh missing at $DEMO_STORE"
  summary_and_exit
fi

if [ ! -x "$DEMO_STORE" ]; then
  fail "$DEMO_STORE exists but is not executable"
  summary_and_exit
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  fail "fixture store missing at $FIXTURE_STORE"
  summary_and_exit
fi

TMP_DEST="$(mktemp -d 2>/dev/null || mktemp -d -t 'demo-store-test')"
cleanup() {
  rm -rf "$TMP_DEST"
}
trap cleanup EXIT

# demo-store.sh must be able to mkdir its own dest; give it a fresh subdir.
DEST="$TMP_DEST/demo"

output="$("$DEMO_STORE" "$DEST" 2>&1)"
status=$?

if [ "$status" -eq 0 ]; then
  pass "demo-store.sh exits 0 against a fresh dest dir"
else
  fail "demo-store.sh exited $status (expected 0) against a fresh dest dir"
  echo "$output"
  summary_and_exit
fi

# --- people count = 30 ---
people_count="$(ls "$DEST"/people/*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$people_count" = "30" ]; then
  pass "demo store has 30 people files"
else
  fail "demo store has $people_count people files (expected 30)"
fi

# --- index.json + stats.json present ---
if [ -f "$DEST/index.json" ]; then
  pass "index.json present in demo store"
else
  fail "index.json missing from demo store"
fi

if [ -f "$DEST/stats.json" ]; then
  pass "stats.json present in demo store"
else
  fail "stats.json missing from demo store"
fi

# --- validate-store.sh passes against the demo store ---
validate_output="$("$REPO_ROOT/packages/core/scripts/validate-store.sh" "$DEST" 2>&1)"
validate_status=$?
if [ "$validate_status" -eq 0 ]; then
  pass "validate-store.sh exits 0 against the demo store"
else
  fail "validate-store.sh exited $validate_status (expected 0) against the demo store"
  echo "$validate_output"
fi

# --- DEMO-STORE.md present ---
if [ -f "$DEST/DEMO-STORE.md" ]; then
  pass "DEMO-STORE.md present in demo store"
else
  fail "DEMO-STORE.md missing from demo store"
fi

# --- inbox/ present ---
if [ -d "$DEST/inbox" ]; then
  pass "inbox/ present in demo store"
else
  fail "inbox/ missing from demo store"
fi

# --- output message mentions people/interaction counts ---
if printf '%s' "$output" | grep -qF "30 synthetic people, 47 interactions"; then
  pass "output reports 30 synthetic people, 47 interactions"
else
  fail "output does not report the expected people/interaction counts"
  echo "$output"
fi

# --- refuses non-empty dest without --force ---
refuse_output="$("$DEMO_STORE" "$DEST" 2>&1)"
refuse_status=$?
if [ "$refuse_status" -eq 2 ]; then
  pass "demo-store.sh exits 2 against a non-empty dest without --force"
else
  fail "demo-store.sh exited $refuse_status (expected 2) against a non-empty dest without --force"
fi

if printf '%s' "$refuse_output" | grep -q '^FAIL:'; then
  pass "refusal output is prefixed with FAIL:"
else
  fail "refusal output missing FAIL: prefix"
  echo "$refuse_output"
fi

# --- succeeds with --force against the same non-empty dest ---
force_output="$("$DEMO_STORE" "$DEST" --force 2>&1)"
force_status=$?
if [ "$force_status" -eq 0 ]; then
  pass "demo-store.sh exits 0 against a non-empty dest with --force"
else
  fail "demo-store.sh exited $force_status (expected 0) against a non-empty dest with --force"
  echo "$force_output"
fi

# --- fixture dir itself must stay pristine (test must run against a temp
#     copy, never write into the committed fixture) ---
if [ -f "$FIXTURE_STORE/index.json" ] || [ -f "$FIXTURE_STORE/stats.json" ]; then
  fail "packages/core/fixtures/store/ gained index.json or stats.json — demo-store.sh must operate on a copy, not the fixture itself"
else
  pass "committed fixture store stays pristine (no index.json/stats.json)"
fi

summary_and_exit
