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

# ---------------------------------------------------------------------------
# assertion 4: plan-11 contract fixtures (profile.md + wakeup 1.0.0/1.1.0)
#
# Each entry below is a standalone mini-store under packages/core/fixtures/
# (its own people/, interactions/, wakeups/, plus a profile.md at the store
# root) isolating exactly one profile.md or wakeup rule from
# packages/core/contracts/profile.md and wakeup.md@1.1.0. "valid" fixtures
# must pass (exit 0); "invalid" fixtures must fail (exit 1).
# ---------------------------------------------------------------------------

plan11_fixtures="
profile-valid:0:profile.md — tagged bullets in every section, birthday — all and job-change — [[slug]] opt-outs
profile-invalid-untagged-bullet:1:profile.md — untagged Priorities bullet
profile-invalid-malformed-optout:1:profile.md — malformed Signal opt-outs grammar
profile-invalid-style-notes-stated:1:profile.md — stated-by-user bullet under Style notes
wakeup-1.0.0-valid:0:wakeup schema_version 1.0.0, no 1.1.0 fields
wakeup-1.1.0-fired-acted-on:0:wakeup 1.1.0 fired with fired-on + acted-on: true
wakeup-1.1.0-dismissed-valid:0:wakeup 1.1.0 dismissed with dismiss-reason: not-this-signal-type
wakeup-1.1.0-snooze-count:0:wakeup 1.1.0 with snooze-count: 2
wakeup-1.1.0-invalid-dismissed-no-reason:1:wakeup 1.1.0 dismissed without dismiss-reason
wakeup-1.1.0-invalid-dismissed-bad-reason:1:wakeup 1.1.0 dismissed with a dismiss-reason outside the enum
"

while IFS=':' read -r fixture_name expected_status desc; do
  [ -z "$fixture_name" ] && continue
  fixture_dir="$REPO_ROOT/packages/core/fixtures/$fixture_name"
  if [ ! -d "$fixture_dir" ]; then
    fail "fixture missing: $fixture_dir ($desc)"
    continue
  fi
  fixture_output="$("$VALIDATOR" "$fixture_dir" 2>&1)"
  fixture_status=$?
  if [ "$fixture_status" -eq "$expected_status" ]; then
    pass "$fixture_name exits $expected_status as expected ($desc)"
  else
    fail "$fixture_name exited $fixture_status (expected $expected_status) ($desc)"
    echo "$fixture_output"
  fi
done <<< "$plan11_fixtures"

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
