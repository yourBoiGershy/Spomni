#!/usr/bin/env bash
# packages/attention/tests/run-capacity-tests.sh
#
# Test suite for packages/attention/scripts/capacity.sh — the sole writer of
# signals/week-plan.json (packages/core/contracts/week-plan.md). Proves
# capacity.sh reproduces the three golden weeks
# (packages/attention/fixtures/capacity/{open-week,busy-week,mixed-week}/)
# exactly, anchored to `--today 2026-08-31`, and handles edge cases.
#
# Scenarios (all built against mktemp scratch stores, never the committed
# fixture dirs directly):
#   1. open-week golden: scratch inbox/ = fixture inbox/, run with
#      --today 2026-08-31, diff jq -S 'del(.generated_at)' of actual vs
#      expected week-plan.json (empty diff), plus generated_at format check.
#   2. busy-week golden: same shape.
#   3. mixed-week golden: same shape.
#   4. empty calendar: scratch store with an empty inbox/ -> exit 0, exactly
#      7 days entries, every day tier open / meeting_hours 0 /
#      largest_free_block_hours 9, weekly_tier open, budget {3,5}.
#   5. stale-input week: scratch store containing only the busy-week events
#      whose occurred_at date is 2026-08-31 or 2026-09-01 -> still exactly 7
#      days entries, dates 2026-08-31..2026-09-06 in order; days 3-7 (Wed..
#      Sun) are zero-event open days.
#   6. failure leaves no partial write: seed scratch signals/week-plan.json
#      with a sentinel, run with an invalid --today -> non-zero exit AND the
#      sentinel file is byte-identical afterward.
#   7. fixtures stay pristine: after all runs, no `signals/` dir exists
#      anywhere under the committed fixtures tree.
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CAPACITY="$REPO_ROOT/packages/attention/scripts/capacity.sh"
FIXTURES="$REPO_ROOT/packages/attention/fixtures/capacity"

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

# --- capacity.sh must exist and be executable ---
if [ ! -f "$CAPACITY" ]; then
  fail "capacity.sh missing at $CAPACITY"
  summary_and_exit
fi

if [ ! -x "$CAPACITY" ]; then
  fail "$CAPACITY exists but is not executable"
  summary_and_exit
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'capacity-test')"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

GENERATED_AT_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# =============================================================================
# Scenarios 1-3: golden weeks
# =============================================================================

run_golden_case() {
  # $1 = scenario name (open-week | busy-week | mixed-week)
  local name="$1"
  local fixture_dir="$FIXTURES/$name"
  local scratch="$TMP_ROOT/golden-$name"

  mkdir -p "$scratch/inbox"
  cp "$fixture_dir/inbox/"*.md "$scratch/inbox/"

  local output status
  output="$("$CAPACITY" "$scratch" --today 2026-08-31 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    pass "$name: capacity.sh exits 0"
  else
    fail "$name: capacity.sh exited $status (expected 0): $output"
    return
  fi

  local actual="$scratch/signals/week-plan.json"
  local expected="$fixture_dir/expected/week-plan.json"

  if [ ! -f "$actual" ]; then
    fail "$name: expected output file not written at $actual"
    return
  fi

  local d
  d="$(diff <(jq -S 'del(.generated_at)' "$actual") <(jq -S 'del(.generated_at)' "$expected") 2>&1)"
  if [ -z "$d" ]; then
    pass "$name: week-plan.json matches golden (ignoring generated_at)"
  else
    fail "$name: week-plan.json diverges from golden:"
    echo "$d"
  fi

  local gen
  gen="$(jq -r '.generated_at' "$actual")"
  if printf '%s' "$gen" | grep -Eq "$GENERATED_AT_RE"; then
    pass "$name: generated_at matches expected format"
  else
    fail "$name: generated_at '$gen' does not match $GENERATED_AT_RE"
  fi
}

run_golden_case "open-week"
run_golden_case "busy-week"
run_golden_case "mixed-week"

# =============================================================================
# Scenario 4: empty calendar
# =============================================================================

S4_DIR="$TMP_ROOT/s4-empty-calendar"
mkdir -p "$S4_DIR/inbox"

s4_output="$("$CAPACITY" "$S4_DIR" --today 2026-08-31 2>&1)"
s4_status=$?

if [ "$s4_status" -eq 0 ]; then
  pass "empty calendar: capacity.sh exits 0"
else
  fail "empty calendar: capacity.sh exited $s4_status (expected 0): $s4_output"
fi

S4_OUT="$S4_DIR/signals/week-plan.json"
if [ -f "$S4_OUT" ]; then
  if jq -e '
      (.days | length) == 7
      and ([.days[] | (.tier == "open" and .meeting_hours == 0 and .largest_free_block_hours == 9)] | all)
      and .weekly_tier == "open"
      and .budget.min == 3
      and .budget.max == 5
    ' "$S4_OUT" >/dev/null 2>&1; then
    pass "empty calendar: 7 open days at 0/9 hours, weekly_tier open, budget {3,5}"
  else
    fail "empty calendar: week-plan.json did not match expected empty-week shape:"
    cat "$S4_OUT"
  fi
else
  fail "empty calendar: no week-plan.json written at $S4_OUT"
fi

# =============================================================================
# Scenario 5: stale-input week (only busy-week events on 2026-08-31 and
# 2026-09-01, filtered by occurred_at date)
# =============================================================================

S5_DIR="$TMP_ROOT/s5-stale-input"
mkdir -p "$S5_DIR/inbox"

for f in "$FIXTURES/busy-week/inbox/"*.md; do
  if grep -qE '^occurred_at: (2026-08-31|2026-09-01)T' "$f"; then
    cp "$f" "$S5_DIR/inbox/"
  fi
done

s5_copied="$(find "$S5_DIR/inbox" -name '*.md' | wc -l | tr -d '[:space:]')"
if [ "$s5_copied" -gt 0 ]; then
  pass "stale-input week: filtered fixture events copied into scratch inbox ($s5_copied files)"
else
  fail "stale-input week: filter matched zero fixture events — test setup is broken"
fi

s5_output="$("$CAPACITY" "$S5_DIR" --today 2026-08-31 2>&1)"
s5_status=$?

if [ "$s5_status" -eq 0 ]; then
  pass "stale-input week: capacity.sh exits 0"
else
  fail "stale-input week: capacity.sh exited $s5_status (expected 0): $s5_output"
fi

S5_OUT="$S5_DIR/signals/week-plan.json"
if [ -f "$S5_OUT" ]; then
  if jq -e '
      (.days | length) == 7
      and ([.days[].date] == ["2026-08-31","2026-09-01","2026-09-02","2026-09-03","2026-09-04","2026-09-05","2026-09-06"])
    ' "$S5_OUT" >/dev/null 2>&1; then
    pass "stale-input week: 7 days entries, dates in order 2026-08-31..2026-09-06"
  else
    fail "stale-input week: days/dates did not match expected shape:"
    cat "$S5_OUT"
  fi

  if jq -e '
      ([.days[2:][] | (.tier == "open" and .events == 0 and .meeting_hours == 0)] | all)
    ' "$S5_OUT" >/dev/null 2>&1; then
    pass "stale-input week: days 3-7 (Wed..Sun) are zero-event open days"
  else
    fail "stale-input week: days 3-7 were not zero-event open days:"
    cat "$S5_OUT"
  fi
else
  fail "stale-input week: no week-plan.json written at $S5_OUT"
fi

# =============================================================================
# Scenario 6: failure leaves no partial write
# =============================================================================

S6_DIR="$TMP_ROOT/s6-failure-no-partial-write"
mkdir -p "$S6_DIR/inbox" "$S6_DIR/signals"
S6_SENTINEL="$S6_DIR/signals/week-plan.json"
printf '{"sentinel":true}' > "$S6_SENTINEL"
S6_PRE="$TMP_ROOT/s6-sentinel-pre.json"
cp "$S6_SENTINEL" "$S6_PRE"

s6_output="$("$CAPACITY" "$S6_DIR" --today not-a-date 2>&1)"
s6_status=$?

if [ "$s6_status" -ne 0 ]; then
  pass "invalid --today: capacity.sh exits non-zero"
else
  fail "invalid --today: capacity.sh exited 0 (expected non-zero): $s6_output"
fi

if cmp -s "$S6_PRE" "$S6_SENTINEL"; then
  pass "invalid --today: sentinel week-plan.json left byte-identical (no partial write)"
else
  fail "invalid --today: sentinel week-plan.json was modified:"
  diff "$S6_PRE" "$S6_SENTINEL"
fi

# =============================================================================
# Scenario 7: fixtures stay pristine
# =============================================================================

s7_leaked="$(find "$FIXTURES" -name signals 2>/dev/null)"
if [ -z "$s7_leaked" ]; then
  pass "fixtures stay pristine: no signals/ dir under the committed fixtures tree"
else
  fail "fixtures stay pristine: found leaked signals/ dir(s):"
  echo "$s7_leaked"
fi

summary_and_exit
