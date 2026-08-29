#!/usr/bin/env bash
# packages/core/tests/test-wakeup-add.sh
#
# Integration test for packages/core/scripts/wakeup-add.sh's wakeup contract
# 1.2.0 event-proposal creation flags, cross-checked against
# packages/core/scripts/validate-store.sh (the first integration check
# between the two — the creator and validator landed from sibling briefs).
#
# Covers:
#   1. --kind event-proposal with all required event flags creates a file
#      matching the contract's 1.2.0 example shape, and the resulting store
#      passes validate-store.sh.
#   2. Event flags supplied without --kind event-proposal are rejected
#      (non-zero exit, no file created).
#   3. --kind event-proposal missing a required event flag (title, then
#      attendee, as a representative pair) is rejected (non-zero exit, no
#      file created).
#   4. Plain nudge creation (no --kind, no event flags) is unchanged: no
#      kind/proposed-event lines in the created file, and the resulting
#      store still passes validate-store.sh.
#
# Each assertion runs against its own mktemp scratch store, cleaned up on
# exit. bash 3.2 portable (no associative arrays, no mapfile).

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WAKEUP_ADD="$REPO_ROOT/packages/core/scripts/wakeup-add.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"

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

SCRATCH_DIRS=""

cleanup() {
  for d in $SCRATCH_DIRS; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

# Creates a fresh scratch store under a mktemp dir, with a single
# people/sam-oyelaran.md so [[sam-oyelaran]] links resolve, and empty
# interactions/ + wakeups/ dirs (validate-store.sh requires all three to
# exist). Prints the store path.
new_scratch_store() {
  local dir
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'wakeup-add-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
  cat > "$dir/people/sam-oyelaran.md" <<'EOF'
---
schema_version: 1.0.0
name: Sam Oyelaran
org: Northwind Analytics
role: Product Manager
location: Austin, TX
tags: [former-colleague]
birthday: --06-02
how-met: Worked together at Northwind
last-touch: 2026-07-01
tier: active
---

## Facts

- **[told-by-user]** Started a new team focused on onboarding flows (2026-07-01)

## Open threads

- _none_

## Personal details

Runs half-marathons.
EOF
  printf '%s\n' "$dir"
}

# --- wakeup-add.sh must exist ---
if [ ! -f "$WAKEUP_ADD" ]; then
  echo "SKIP: $WAKEUP_ADD not found — cannot run wakeup-add tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, wakeup-add.sh missing"
  exit 1
fi

if [ ! -x "$WAKEUP_ADD" ]; then
  echo "FAIL: $WAKEUP_ADD exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$VALIDATOR" ]; then
  echo "FAIL: $VALIDATOR not found or not executable — cannot cross-check wakeup-add.sh output"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# assertion 1: valid event-proposal creation matches the 1.2.0 shape and
# passes validate-store.sh
# ---------------------------------------------------------------------------

store1="$(new_scratch_store)"
created_path="$("$WAKEUP_ADD" "$store1" \
  --due 2026-09-05 --person sam-oyelaran --why "scheduling intent: coffee" \
  --origin user-ask \
  --kind event-proposal \
  --event-title "Coffee with Sam" \
  --event-start "2026-09-08T10:00:00-07:00" \
  --event-end "2026-09-08T11:00:00-07:00" \
  --event-attendee sam-oyelaran \
  2>&1)"
created_status=$?

if [ "$created_status" -eq 0 ] && [ -f "$created_path" ]; then
  pass "wakeup-add.sh exits 0 and creates a file for a valid event-proposal"
else
  fail "wakeup-add.sh exited $created_status or produced no file for a valid event-proposal (output: $created_path)"
fi

if [ -f "$created_path" ]; then
  shape_ok=1
  for expected in \
    'schema_version: 1.2.0' \
    'kind: event-proposal' \
    'proposed-event:' \
    '  title: Coffee with Sam' \
    '  start: 2026-09-08T10:00:00-07:00' \
    '  end: 2026-09-08T11:00:00-07:00' \
    '  attendees: \["\[\[sam-oyelaran\]\]"\]' \
    'confirmed-on:' \
    'created-event-id:'
  do
    if ! grep -qE "^${expected}$" "$created_path"; then
      shape_ok=0
      fail "created file missing expected line matching /^${expected}\$/"
    fi
  done
  if [ "$shape_ok" -eq 1 ]; then
    pass "created event-proposal file matches the contract's 1.2.0 example shape"
  fi

  proposal_output="$("$VALIDATOR" "$store1" 2>&1)"
  proposal_status=$?
  if [ "$proposal_status" -eq 0 ]; then
    pass "validate-store.sh exits 0 on the store containing the created event-proposal"
  else
    fail "validate-store.sh exited $proposal_status (expected 0) on the store containing the created event-proposal"
    echo "$proposal_output"
  fi
else
  fail "cannot check 1.2.0 shape or validate-store.sh — no file was created"
fi

# ---------------------------------------------------------------------------
# assertion 2: event flags without --kind event-proposal are rejected
# ---------------------------------------------------------------------------

store2="$(new_scratch_store)"
before_count="$(ls "$store2/wakeups" | wc -l | tr -d ' ')"
reject_output="$("$WAKEUP_ADD" "$store2" \
  --due 2026-09-05 --person sam-oyelaran --why "scheduling intent: coffee" \
  --origin user-ask \
  --event-title "Coffee with Sam" \
  --event-start "2026-09-08T10:00:00-07:00" \
  --event-end "2026-09-08T11:00:00-07:00" \
  --event-attendee sam-oyelaran \
  2>&1)"
reject_status=$?
after_count="$(ls "$store2/wakeups" | wc -l | tr -d ' ')"

if [ "$reject_status" -ne 0 ]; then
  pass "wakeup-add.sh rejects event flags supplied without --kind event-proposal (exit $reject_status)"
else
  fail "wakeup-add.sh exited 0 for event flags without --kind event-proposal (expected non-zero)"
fi

if [ "$after_count" -eq "$before_count" ]; then
  pass "no file created when event flags are rejected for missing --kind event-proposal"
else
  fail "a file was created despite event flags being rejected (before=$before_count, after=$after_count)"
fi

# ---------------------------------------------------------------------------
# assertion 3: --kind event-proposal missing a required event flag is
# rejected (representative pair: missing --event-title, missing
# --event-attendee)
# ---------------------------------------------------------------------------

store3="$(new_scratch_store)"
before_count3="$(ls "$store3/wakeups" | wc -l | tr -d ' ')"
missing_title_status=1
"$WAKEUP_ADD" "$store3" \
  --due 2026-09-05 --person sam-oyelaran --why "scheduling intent: coffee" \
  --origin user-ask \
  --kind event-proposal \
  --event-start "2026-09-08T10:00:00-07:00" \
  --event-end "2026-09-08T11:00:00-07:00" \
  --event-attendee sam-oyelaran \
  >/dev/null 2>&1
missing_title_status=$?
after_count3a="$(ls "$store3/wakeups" | wc -l | tr -d ' ')"

if [ "$missing_title_status" -ne 0 ] && [ "$after_count3a" -eq "$before_count3" ]; then
  pass "wakeup-add.sh rejects --kind event-proposal missing --event-title (exit $missing_title_status, no file created)"
else
  fail "wakeup-add.sh did not reject --kind event-proposal missing --event-title (exit=$missing_title_status, before=$before_count3, after=$after_count3a)"
fi

missing_attendee_status=1
"$WAKEUP_ADD" "$store3" \
  --due 2026-09-05 --person sam-oyelaran --why "scheduling intent: coffee" \
  --origin user-ask \
  --kind event-proposal \
  --event-title "Coffee with Sam" \
  --event-start "2026-09-08T10:00:00-07:00" \
  --event-end "2026-09-08T11:00:00-07:00" \
  >/dev/null 2>&1
missing_attendee_status=$?
after_count3b="$(ls "$store3/wakeups" | wc -l | tr -d ' ')"

if [ "$missing_attendee_status" -ne 0 ] && [ "$after_count3b" -eq "$before_count3" ]; then
  pass "wakeup-add.sh rejects --kind event-proposal missing --event-attendee (exit $missing_attendee_status, no file created)"
else
  fail "wakeup-add.sh did not reject --kind event-proposal missing --event-attendee (exit=$missing_attendee_status, before=$before_count3, after=$after_count3b)"
fi

# ---------------------------------------------------------------------------
# assertion 4: plain nudge creation is unchanged — no kind/proposed-event
# lines, and the store still passes validate-store.sh
# ---------------------------------------------------------------------------

store4="$(new_scratch_store)"
nudge_path="$("$WAKEUP_ADD" "$store4" \
  --due 2026-09-05 --person sam-oyelaran --why "quarterly check-in" \
  --origin standing \
  2>&1)"
nudge_status=$?

if [ "$nudge_status" -eq 0 ] && [ -f "$nudge_path" ]; then
  pass "wakeup-add.sh exits 0 and creates a file for a plain nudge"
else
  fail "wakeup-add.sh exited $nudge_status or produced no file for a plain nudge (output: $nudge_path)"
fi

if [ -f "$nudge_path" ]; then
  if grep -qE '^schema_version: 1.0.0$' "$nudge_path" \
    && ! grep -qE '^kind:' "$nudge_path" \
    && ! grep -qE '^proposed-event:' "$nudge_path" \
    && ! grep -qE '^confirmed-on:' "$nudge_path" \
    && ! grep -qE '^created-event-id:' "$nudge_path"
  then
    pass "plain nudge file has schema_version 1.0.0 and no kind/proposed-event/confirmed-on/created-event-id lines"
  else
    fail "plain nudge file unexpectedly carries 1.2.0 fields"
    cat "$nudge_path"
  fi

  nudge_validate_output="$("$VALIDATOR" "$store4" 2>&1)"
  nudge_validate_status=$?
  if [ "$nudge_validate_status" -eq 0 ]; then
    pass "validate-store.sh exits 0 on the store containing the plain nudge"
  else
    fail "validate-store.sh exited $nudge_validate_status (expected 0) on the store containing the plain nudge"
    echo "$nudge_validate_output"
  fi
else
  fail "cannot check nudge shape or validate-store.sh — no file was created"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
