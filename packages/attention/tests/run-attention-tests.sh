#!/usr/bin/env bash
# packages/attention/tests/run-attention-tests.sh
#
# Test suite for packages/attention/scripts/wakeup-queue.sh's confirm/decline
# ops (ported verbatim from the now-retired proposal-confirm.sh, per
# packages/core/contracts/wakeup.md 1.2.0), run against the Wave A
# scheduling-intent fixtures (packages/attention/tests/fixtures/
# scheduling-intent/). This is attention's first runnable script-test entry
# point.
#
# Scenarios (all built against mktemp scratch stores, never the committed
# fixture dirs):
#   1. confirm on a pending proposal (clear-intent/expected/proposal-wakeup.md,
#      extracted from its fenced doc) -> exactly confirmed-on/created-event-id/
#      acted-on change, byte-identical otherwise, passes validate-store.sh.
#   2. decline on a pending proposal -> only status/dismiss-reason change,
#      byte-identical otherwise, passes validate-store.sh, and no new files
#      appear anywhere in the store (silent-decline doctrine).
#   3. refusals, each asserted to exit non-zero AND leave the whole scratch
#      store byte-identical to its pre-image:
#        a. confirm without --event-id
#        b. confirm on a kind: nudge wake-up
#           (calibration-basic/wakeups/2026-06-01-petra-lindholm.md — no
#           `kind` field, which reads as nudge per proposal-confirm.sh)
#        c. confirm on an already-dismissed event-proposal
#           (declined-proposal/wakeups/2026-08-19-marisol-vance.md)
#        d. decline with an invalid --reason
#
# confirm deliberately never touches `status` — the wakeup status enum
# (pending/fired/snoozed/dismissed) has no "confirmed" member, so a confirmed
# pending proposal's status line must still read `status: pending` afterward.
# See wakeup-queue.sh's own header comment (confirm/decline op section).
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CONFIRM="$REPO_ROOT/packages/attention/scripts/wakeup-queue.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURES="$REPO_ROOT/packages/attention/tests/fixtures/scheduling-intent"
CALIBRATION_FIXTURES="$REPO_ROOT/packages/attention/tests/fixtures/calibration-basic"

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

# --- wakeup-queue.sh must exist and be executable ---
if [ ! -f "$CONFIRM" ]; then
  echo "SKIP: $CONFIRM not found — cannot run attention tests yet."
  fail "wakeup-queue.sh missing at $CONFIRM"
  summary_and_exit
fi

if [ ! -x "$CONFIRM" ]; then
  fail "$CONFIRM exists but is not executable"
  summary_and_exit
fi

if [ ! -f "$VALIDATOR" ]; then
  fail "validate-store.sh missing at $VALIDATOR"
  summary_and_exit
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'attention-test')"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# --- fenced-doc extraction: clear-intent/expected/proposal-wakeup.md wraps
#     the actual wake-up file content in a ```markdown fence; pull just that
#     content out to build a real store file from it. ---
extract_fenced_wakeup() {
  # $1 = source doc (with a ```markdown ... ``` fence), $2 = output path
  awk '
    /^```markdown$/ { p = 1; next }
    /^```$/ { if (p) { p = 0; exit } }
    p { print }
  ' "$1" > "$2"
}

# --- store builders (each populates a fresh dir with people/interactions/
#     wakeups siblings, mirroring what validate-store.sh expects) ---

build_theo_store() {
  # a pending kind: event-proposal wake-up for Theo Bramwell
  local dir="$1"
  mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
  cp "$FIXTURES/clear-intent/people/theo-bramwell.md" "$dir/people/"
  cp "$FIXTURES/clear-intent/interactions/"*.md "$dir/interactions/"
  extract_fenced_wakeup "$FIXTURES/clear-intent/expected/proposal-wakeup.md" \
    "$dir/wakeups/2026-08-31-theo-bramwell.md"
}

build_marisol_store() {
  # an already-dismissed kind: event-proposal wake-up for Marisol Vance
  local dir="$1"
  mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
  cp "$FIXTURES/declined-proposal/people/marisol-vance.md" "$dir/people/"
  cp "$FIXTURES/declined-proposal/interactions/"*.md "$dir/interactions/"
  cp "$FIXTURES/declined-proposal/wakeups/2026-08-19-marisol-vance.md" "$dir/wakeups/"
}

build_petra_store() {
  # a kind: nudge (no `kind` field at all) wake-up for Petra Lindholm
  local dir="$1"
  mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
  cp "$CALIBRATION_FIXTURES/people/petra-lindholm.md" "$dir/people/"
  cp "$CALIBRATION_FIXTURES/wakeups/2026-06-01-petra-lindholm.md" "$dir/wakeups/"
}

if [ ! -f "$FIXTURES/clear-intent/expected/proposal-wakeup.md" ]; then
  fail "fixture missing: $FIXTURES/clear-intent/expected/proposal-wakeup.md"
  summary_and_exit
fi

# =============================================================================
# Scenario 1: confirm on a pending proposal
# =============================================================================

S1_DIR="$TMP_ROOT/s1-confirm-pending"
build_theo_store "$S1_DIR"
S1_WAKEUP="$S1_DIR/wakeups/2026-08-31-theo-bramwell.md"

if [ ! -f "$S1_WAKEUP" ]; then
  fail "scenario 1 setup: extracted wake-up file not found at $S1_WAKEUP (fenced-doc extraction produced nothing)"
else
  S1_PRE="$TMP_ROOT/s1-pre-image.md"
  cp "$S1_WAKEUP" "$S1_PRE"

  S1_EVENT_ID="gcal-evt-abc123"
  S1_TODAY="$(date -u +%Y-%m-%d)"

  s1_output="$("$CONFIRM" "$S1_DIR" confirm 2026-08-31-theo-bramwell --event-id "$S1_EVENT_ID" 2>&1)"
  s1_status=$?

  if [ "$s1_status" -eq 0 ]; then
    pass "confirm on a pending proposal exits 0"
  else
    fail "confirm on a pending proposal exited $s1_status (expected 0): $s1_output"
  fi

  # expected post-image: pre-image with exactly the 3 confirm fields filled in
  S1_EXPECTED="$TMP_ROOT/s1-expected.md"
  sed \
    -e "s/^confirmed-on:\$/confirmed-on: ${S1_TODAY}/" \
    -e "s/^created-event-id:\$/created-event-id: ${S1_EVENT_ID}/" \
    -e "s/^acted-on:\$/acted-on: true/" \
    "$S1_PRE" > "$S1_EXPECTED"

  s1_diff="$(diff -u "$S1_EXPECTED" "$S1_WAKEUP" 2>&1)"
  if [ -z "$s1_diff" ]; then
    pass "confirm on a pending proposal changes ONLY confirmed-on/created-event-id/acted-on (byte-identical otherwise)"
  else
    fail "confirm on a pending proposal changed more than the 3 expected fields:"
    echo "$s1_diff"
  fi

  # status must remain untouched (still 'pending' — confirm never writes status)
  if grep -qx "status: pending" "$S1_WAKEUP"; then
    pass "confirm on a pending proposal leaves status: pending untouched"
  else
    fail "confirm on a pending proposal did not leave status: pending untouched"
  fi

  # the invariant: created-event-id and confirmed-on both set in the same op
  if grep -q "^confirmed-on: ${S1_TODAY}\$" "$S1_WAKEUP" && grep -q "^created-event-id: ${S1_EVENT_ID}\$" "$S1_WAKEUP"; then
    pass "confirm writes confirmed-on and created-event-id together in one op"
  else
    fail "confirm did not write both confirmed-on and created-event-id"
  fi

  s1_validate_output="$("$VALIDATOR" "$S1_DIR" 2>&1)"
  s1_validate_status=$?
  if [ "$s1_validate_status" -eq 0 ]; then
    pass "store still passes validate-store.sh after confirm"
  else
    fail "validate-store.sh exited $s1_validate_status (expected 0) after confirm:"
    echo "$s1_validate_output"
  fi
fi

# =============================================================================
# Scenario 2: decline on a pending proposal
# =============================================================================

S2_DIR="$TMP_ROOT/s2-decline-pending"
build_theo_store "$S2_DIR"
S2_WAKEUP="$S2_DIR/wakeups/2026-08-31-theo-bramwell.md"

if [ ! -f "$S2_WAKEUP" ]; then
  fail "scenario 2 setup: extracted wake-up file not found at $S2_WAKEUP"
else
  S2_PRE="$TMP_ROOT/s2-pre-image.md"
  cp "$S2_WAKEUP" "$S2_PRE"
  S2_FILES_BEFORE="$(find "$S2_DIR" -type f | sort)"

  s2_output="$("$CONFIRM" "$S2_DIR" decline 2026-08-31-theo-bramwell --reason not-now 2>&1)"
  s2_status=$?

  if [ "$s2_status" -eq 0 ]; then
    pass "decline on a pending proposal exits 0"
  else
    fail "decline on a pending proposal exited $s2_status (expected 0): $s2_output"
  fi

  S2_EXPECTED="$TMP_ROOT/s2-expected.md"
  sed \
    -e "s/^status: pending\$/status: dismissed/" \
    -e "s/^dismiss-reason:\$/dismiss-reason: not-now/" \
    "$S2_PRE" > "$S2_EXPECTED"

  s2_diff="$(diff -u "$S2_EXPECTED" "$S2_WAKEUP" 2>&1)"
  if [ -z "$s2_diff" ]; then
    pass "decline on a pending proposal changes ONLY status/dismiss-reason (byte-identical otherwise)"
  else
    fail "decline on a pending proposal changed more than status/dismiss-reason:"
    echo "$s2_diff"
  fi

  s2_validate_output="$("$VALIDATOR" "$S2_DIR" 2>&1)"
  s2_validate_status=$?
  if [ "$s2_validate_status" -eq 0 ]; then
    pass "store still passes validate-store.sh after decline"
  else
    fail "validate-store.sh exited $s2_validate_status (expected 0) after decline:"
    echo "$s2_validate_output"
  fi

  S2_FILES_AFTER="$(find "$S2_DIR" -type f | sort)"
  if [ "$S2_FILES_BEFORE" = "$S2_FILES_AFTER" ]; then
    pass "decline creates no new files anywhere in the store (silent-decline doctrine)"
  else
    fail "decline changed the store's file listing (silent-decline doctrine violated):"
    diff <(printf '%s\n' "$S2_FILES_BEFORE") <(printf '%s\n' "$S2_FILES_AFTER")
  fi
fi

# =============================================================================
# Scenario 3: refusals — each must exit non-zero and leave the whole scratch
# store byte-identical to its pre-image (diff -r against a full copy).
# =============================================================================

assert_refusal() {
  # $1 = description, $2 = store dir to operate on, remaining args = the
  # proposal-confirm.sh invocation's action/wakeup-id/flags
  local desc="$1" dir="$2"
  shift 2

  local pre_copy
  pre_copy="$(mktemp -d 2>/dev/null || mktemp -d -t 'attention-test-pre')"
  cp -R "$dir/." "$pre_copy/"

  local output status
  output="$("$CONFIRM" "$dir" "$@" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ]; then
    pass "$desc: exits non-zero"
  else
    fail "$desc: exited 0 (expected non-zero): $output"
  fi

  local dirdiff
  dirdiff="$(diff -r "$pre_copy" "$dir" 2>&1)"
  if [ -z "$dirdiff" ]; then
    pass "$desc: leaves the store byte-identical"
  else
    fail "$desc: store was NOT left byte-identical:"
    echo "$dirdiff"
  fi

  rm -rf "$pre_copy"
}

# 3a. confirm without --event-id
S3A_DIR="$TMP_ROOT/s3a-confirm-no-event-id"
build_theo_store "$S3A_DIR"
assert_refusal "confirm without --event-id" "$S3A_DIR" confirm 2026-08-31-theo-bramwell

# 3b. confirm on kind: nudge (petra-lindholm has no `kind` field -> reads as nudge)
S3B_DIR="$TMP_ROOT/s3b-confirm-nudge"
build_petra_store "$S3B_DIR"
assert_refusal "confirm on kind: nudge" "$S3B_DIR" confirm 2026-06-01-petra-lindholm --event-id gcal-evt-xyz

# 3c. confirm on an already-dismissed event-proposal
S3C_DIR="$TMP_ROOT/s3c-confirm-already-dismissed"
build_marisol_store "$S3C_DIR"
assert_refusal "confirm on an already-dismissed event-proposal" "$S3C_DIR" confirm 2026-08-19-marisol-vance --event-id gcal-evt-999

# 3d. decline with an invalid reason
S3D_DIR="$TMP_ROOT/s3d-decline-invalid-reason"
build_theo_store "$S3D_DIR"
assert_refusal "decline with an invalid reason" "$S3D_DIR" decline 2026-08-31-theo-bramwell --reason not-a-real-reason

summary_and_exit
