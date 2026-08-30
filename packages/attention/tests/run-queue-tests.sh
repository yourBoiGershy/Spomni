#!/usr/bin/env bash
# packages/attention/tests/run-queue-tests.sh
#
# Test suite for packages/attention/scripts/wakeup-queue.sh's list-due/fire/
# snooze/dismiss lifecycle (packages/core/contracts/wakeup.md 1.2.0,
# packages/attention/specs/outcome-recording.md). confirm/decline are
# covered separately by run-attention-tests.sh.
#
# Scenarios (all built against mktemp scratch stores via
# packages/core/scripts/wakeup-add.sh, never the committed fixture dirs):
#   1. list-due windows (today/yesterday listed, tomorrow not; --json valid)
#   2. fire basics (status: fired, fired-on, one batch file, future untouched)
#   3. fire idempotent (second identical run: no new batch, byte-identical)
#   4. budget (user-ask exempt, signal entries capped by week-plan budget.max,
#      held-budget reporting, exhausted budget blocks a later fresh entry)
#   5. missing week-plan.json -> WARN + budget.max fallback of 3
#   6. meeting adjacency (whole run held near a same-day calendar-event
#      capture; fires once outside the adjacency window)
#   7. snooze (due-forward, status pending, snooze-count increments,
#      fired-on preserved across fire->snooze, 1.0.0 -> 1.1.0 upgrade shape)
#   8. dismiss (valid reason, invalid reason refusal, double-dismiss refusal)
#   9. validate-store.sh clean after the full lifecycle
#   10. event-proposal fires with kind + proposed_event in the batch
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

QUEUE="$REPO_ROOT/packages/attention/scripts/wakeup-queue.sh"
WAKEUP_ADD="$REPO_ROOT/packages/core/scripts/wakeup-add.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
PERSON_FIXTURE="$REPO_ROOT/packages/core/fixtures/store/people/aiko-tanaka.md"
WEEK_PLAN_FIXTURE="$REPO_ROOT/packages/attention/fixtures/capacity/busy-week/expected/week-plan.json"
INBOX_FIXTURE="$REPO_ROOT/packages/attention/fixtures/capacity/busy-week/inbox/20260830T080000Z-calendar-in-calendar-bw01.md"

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

for req in "$QUEUE" "$WAKEUP_ADD" "$VALIDATOR" "$PERSON_FIXTURE" "$WEEK_PLAN_FIXTURE" "$INBOX_FIXTURE"; do
  if [ ! -f "$req" ]; then
    fail "required file missing: $req"
    summary_and_exit
  fi
done

if [ ! -x "$QUEUE" ]; then
  fail "$QUEUE exists but is not executable"
  summary_and_exit
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'queue-test')"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# --- store builder: people/ with the aiko-tanaka fixture, empty
#     interactions/ and wakeups/ dirs (mirrors what validate-store.sh
#     expects) ---
new_store() {
  local dir="$1"
  mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
  cp "$PERSON_FIXTURE" "$dir/people/"
}

# add_wakeup <store> [wakeup-add.sh args...] -> prints created path
add_wakeup() {
  local dir="$1"
  shift
  "$WAKEUP_ADD" "$dir" "$@"
}

# =============================================================================
# Scenario 1: list-due windows
# =============================================================================

S1_DIR="$TMP_ROOT/s1-list-due"
new_store "$S1_DIR"

S1_TODAY_FILE="$(add_wakeup "$S1_DIR" --due 2026-09-02 --person aiko-tanaka --why "today" --origin user-ask)"
S1_YEST_FILE="$(add_wakeup "$S1_DIR" --due 2026-09-01 --person aiko-tanaka --why "yesterday" --origin user-ask)"
S1_TOMORROW_FILE="$(add_wakeup "$S1_DIR" --due 2026-09-03 --person aiko-tanaka --why "tomorrow" --origin user-ask)"

S1_TODAY_ID="2026-09-02-aiko-tanaka"
S1_YEST_ID="2026-09-01-aiko-tanaka"
S1_TOMORROW_ID="2026-09-03-aiko-tanaka"

s1_list="$("$QUEUE" "$S1_DIR" list-due --today 2026-09-02)"
if printf '%s\n' "$s1_list" | grep -qx "$S1_TODAY_ID" && printf '%s\n' "$s1_list" | grep -qx "$S1_YEST_ID"; then
  pass "list-due lists due-today and due-yesterday"
else
  fail "list-due did not list both due-today and due-yesterday: $s1_list"
fi

if printf '%s\n' "$s1_list" | grep -qx "$S1_TOMORROW_ID"; then
  fail "list-due listed a due-tomorrow entry (should not be due yet)"
else
  pass "list-due does not list a due-tomorrow entry"
fi

s1_json="$("$QUEUE" "$S1_DIR" list-due --today 2026-09-02 --json)"
if printf '%s' "$s1_json" | jq -e '.' >/dev/null 2>&1; then
  pass "list-due --json produces valid JSON"
else
  fail "list-due --json produced invalid JSON: $s1_json"
fi

s1_json_ids="$(printf '%s' "$s1_json" | jq -r '.[].id' | sort)"
s1_expected_ids="$(printf '%s\n%s\n' "$S1_TODAY_ID" "$S1_YEST_ID" | sort)"
if [ "$s1_json_ids" = "$s1_expected_ids" ]; then
  pass "list-due --json ids match the due-today/due-yesterday entries"
else
  fail "list-due --json ids mismatch: got [$s1_json_ids] expected [$s1_expected_ids]"
fi

# =============================================================================
# Scenario 2: fire basics
# =============================================================================

S2_DIR="$TMP_ROOT/s2-fire-basics"
new_store "$S2_DIR"

add_wakeup "$S2_DIR" --due 2026-09-01 --person aiko-tanaka --why "due1" --origin user-ask >/dev/null
add_wakeup "$S2_DIR" --due 2026-09-02 --person aiko-tanaka --why "due2" --origin user-ask >/dev/null
S2_FUTURE_FILE="$(add_wakeup "$S2_DIR" --due 2026-09-03 --person aiko-tanaka --why "future" --origin user-ask)"

s2_out="$("$QUEUE" "$S2_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z 2>&1)"
s2_status=$?

if [ "$s2_status" -eq 0 ]; then
  pass "fire basics exits 0"
else
  fail "fire basics exited $s2_status: $s2_out"
fi

s2_fired_count="$(grep -c '^status: fired$' "$S2_DIR"/wakeups/*.md 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')"
s2_fired_files_count="$(grep -l '^status: fired$' "$S2_DIR"/wakeups/*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s2_fired_files_count" = "2" ]; then
  pass "fire basics: exactly the two due entries got status: fired"
else
  fail "fire basics: expected 2 fired entries, got $s2_fired_files_count"
fi

if grep -q '^fired-on: 2026-09-02$' "$S2_DIR"/wakeups/2026-09-01-aiko-tanaka.md 2>/dev/null \
  && grep -q '^fired-on: 2026-09-02$' "$S2_DIR"/wakeups/2026-09-02-aiko-tanaka.md 2>/dev/null; then
  pass "fire basics: fired-on set to --today on both fired entries"
else
  fail "fire basics: fired-on not set correctly"
fi

if grep -q '^status: pending$' "$S2_FUTURE_FILE"; then
  pass "fire basics: future entry left untouched (still pending)"
else
  fail "fire basics: future entry was modified: $(cat "$S2_FUTURE_FILE")"
fi

S2_BATCH_COUNT="$(find "$S2_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$S2_BATCH_COUNT" = "1" ]; then
  pass "fire basics: exactly one batch file written"
else
  fail "fire basics: expected 1 batch file, found $S2_BATCH_COUNT"
fi

S2_BATCH_FILE="$(find "$S2_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | head -n1)"
S2_BATCH_IDS="$(jq -r '.entries[].id' "$S2_BATCH_FILE" 2>/dev/null | sort)"
S2_EXPECTED_IDS="$(printf '%s\n%s\n' 2026-09-01-aiko-tanaka 2026-09-02-aiko-tanaka | sort)"
if [ "$S2_BATCH_IDS" = "$S2_EXPECTED_IDS" ]; then
  pass "fire basics: batch entries ids match the two fired entries"
else
  fail "fire basics: batch entries ids mismatch: got [$S2_BATCH_IDS] expected [$S2_EXPECTED_IDS]"
fi

# =============================================================================
# Scenario 3: fire idempotent
# =============================================================================

S3_SNAPSHOT="$TMP_ROOT/s3-snapshot"
cp -R "$S2_DIR" "$S3_SNAPSHOT"

s3_out="$("$QUEUE" "$S2_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z 2>&1)"
s3_status=$?

S3_BATCH_COUNT_AFTER="$(find "$S2_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s3_status" -eq 0 ] && [ "$S3_BATCH_COUNT_AFTER" = "1" ]; then
  pass "fire idempotent: second run writes no new batch file"
else
  fail "fire idempotent: status=$s3_status batch_count=$S3_BATCH_COUNT_AFTER output=$s3_out"
fi

s3_diff="$(diff -r "$S3_SNAPSHOT" "$S2_DIR" 2>&1)"
if [ -z "$s3_diff" ]; then
  pass "fire idempotent: store byte-identical after the second run"
else
  fail "fire idempotent: store changed on the second run:"
  echo "$s3_diff"
fi

# =============================================================================
# Scenario 4: budget
# =============================================================================

S4_DIR="$TMP_ROOT/s4-budget"
new_store "$S4_DIR"
mkdir -p "$S4_DIR/signals"
cp "$WEEK_PLAN_FIXTURE" "$S4_DIR/signals/week-plan.json"
# fixture week_start is 2026-08-31, generated_at 2026-08-31T18:00:00Z, budget.max: 2

add_wakeup "$S4_DIR" --due 2026-09-02 --person aiko-tanaka --why "sig1" --origin signal --source-signal sig-1 >/dev/null
add_wakeup "$S4_DIR" --due 2026-09-02 --person aiko-tanaka --why "sig2" --origin signal --source-signal sig-2 >/dev/null
add_wakeup "$S4_DIR" --due 2026-09-02 --person aiko-tanaka --why "sig3" --origin signal --source-signal sig-3 >/dev/null
add_wakeup "$S4_DIR" --due 2026-09-02 --person aiko-tanaka --why "ua1" --origin user-ask >/dev/null

s4_out="$("$QUEUE" "$S4_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z 2>&1)"

S4_BATCH_FILE="$(find "$S4_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | head -n1)"
if [ -n "$S4_BATCH_FILE" ]; then
  s4_used_after="$(jq -r '.budget.used_after' "$S4_BATCH_FILE")"
  s4_entry_count="$(jq -r '.entries | length' "$S4_BATCH_FILE")"
  s4_held_budget="$(jq -r '.held_budget' "$S4_BATCH_FILE")"
  if [ "$s4_entry_count" = "3" ] && [ "$s4_used_after" = "2" ]; then
    pass "budget: user-ask + 2 signal entries fire (used_after == 2)"
  else
    fail "budget: expected 3 fired entries and used_after 2, got entry_count=$s4_entry_count used_after=$s4_used_after"
  fi
  if [ "$(printf '%s' "$s4_held_budget" | jq 'length')" = "1" ]; then
    pass "budget: exactly one signal entry held-budget"
  else
    fail "budget: expected exactly one held_budget entry, got: $s4_held_budget"
  fi
else
  fail "budget: no batch file written"
fi

s4_pending_count="$(grep -l '^status: pending$' "$S4_DIR"/wakeups/*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s4_pending_count" = "1" ]; then
  pass "budget: exactly one signal entry remains pending"
else
  fail "budget: expected 1 remaining pending entry, got $s4_pending_count"
fi

# a later run in the same week with a fresh signal entry: budget already
# exhausted (used_after == 2 == budget.max) -> fires nothing further
add_wakeup "$S4_DIR" --due 2026-09-02 --person aiko-tanaka --why "sig4" --origin signal --source-signal sig-4 >/dev/null
S4_BATCH_COUNT_BEFORE="$(find "$S4_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
s4b_out="$("$QUEUE" "$S4_DIR" fire --today 2026-09-02 --now 2026-09-02T15:00:00Z 2>&1)"
S4_BATCH_COUNT_AFTER="$(find "$S4_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

if [ "$S4_BATCH_COUNT_BEFORE" = "$S4_BATCH_COUNT_AFTER" ] && printf '%s\n' "$s4b_out" | grep -q '^held-budget:'; then
  pass "budget: exhausted budget blocks a later fresh signal entry (no new batch)"
else
  fail "budget: fresh signal entry should have been held-budget with no new batch: before=$S4_BATCH_COUNT_BEFORE after=$S4_BATCH_COUNT_AFTER output=$s4b_out"
fi

# =============================================================================
# Scenario 5: missing week-plan.json
# =============================================================================

S5_DIR="$TMP_ROOT/s5-missing-week-plan"
new_store "$S5_DIR"
add_wakeup "$S5_DIR" --due 2026-09-02 --person aiko-tanaka --why "sig" --origin signal --source-signal sig-1 >/dev/null

s5_out="$("$QUEUE" "$S5_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z 2>&1 1>"$TMP_ROOT/s5-stdout")"
s5_status=$?
if [ "$s5_status" -eq 0 ]; then
  pass "missing week-plan: fire still succeeds"
else
  fail "missing week-plan: fire exited $s5_status: $s5_out"
fi

if printf '%s' "$s5_out" | grep -qi 'WARN'; then
  pass "missing week-plan: WARN printed on stderr"
else
  fail "missing week-plan: no WARN printed: $s5_out"
fi

S5_BATCH_FILE="$(find "$S5_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | head -n1)"
if [ -n "$S5_BATCH_FILE" ]; then
  s5_max="$(jq -r '.budget.max' "$S5_BATCH_FILE")"
  if [ "$s5_max" = "3" ]; then
    pass "missing week-plan: budget.max falls back to 3"
  else
    fail "missing week-plan: expected budget.max 3, got $s5_max"
  fi
else
  fail "missing week-plan: no batch file written"
fi

# =============================================================================
# Scenario 6: meeting adjacency
# =============================================================================

S6_DIR="$TMP_ROOT/s6-adjacency"
new_store "$S6_DIR"
mkdir -p "$S6_DIR/inbox"

S6_INBOX_FILE="$S6_DIR/inbox/20260902-calendar-in-adjacent.md"
{
  echo "---"
  echo "schema_version: 1.2.0"
  echo "id: 20260902-calendar-in-adjacent"
  echo "source: calendar-in/calendar"
  echo "captured_at: 2026-09-02T08:00:00Z"
  echo "occurred_at: 2026-09-02T14:00:00Z"
  echo "type: calendar-event"
  echo "participant-hints:"
  echo "  - \"Aiko Tanaka <aiko.tanaka@example.com>\""
  echo "---"
  echo "{"
  echo "  \"summary\": \"Aiko sync\","
  echo "  \"start\": { \"dateTime\": \"2026-09-02T14:00:00Z\" },"
  echo "  \"end\": { \"dateTime\": \"2026-09-02T15:00:00Z\" },"
  echo "  \"attendees\": [ { \"email\": \"aiko.tanaka@example.com\", \"displayName\": \"Aiko Tanaka\" } ]"
  echo "}"
} > "$S6_INBOX_FILE"

add_wakeup "$S6_DIR" --due 2026-09-02 --person aiko-tanaka --why "adjacent" --origin user-ask >/dev/null

s6a_out="$("$QUEUE" "$S6_DIR" fire --today 2026-09-02 --now 2026-09-02T13:45:00Z 2>&1)"
s6a_batch_count="$(find "$S6_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
if printf '%s\n' "$s6a_out" | grep -q '^held-adjacent: 2026-09-02-aiko-tanaka$' && [ "$s6a_batch_count" = "0" ]; then
  pass "adjacency: fire held near the meeting, no batch written"
else
  fail "adjacency: expected held-adjacent and no batch, got batch_count=$s6a_batch_count output=$s6a_out"
fi

if grep -q '^status: pending$' "$S6_DIR/wakeups/2026-09-02-aiko-tanaka.md"; then
  pass "adjacency: held entry still pending"
else
  fail "adjacency: held entry was modified"
fi

s6b_out="$("$QUEUE" "$S6_DIR" fire --today 2026-09-02 --now 2026-09-02T16:00:00Z 2>&1)"
if grep -q '^status: fired$' "$S6_DIR/wakeups/2026-09-02-aiko-tanaka.md"; then
  pass "adjacency: fires once outside the adjacency window"
else
  fail "adjacency: entry did not fire outside the window: $s6b_out"
fi

# =============================================================================
# Scenario 7: snooze
# =============================================================================

S7_DIR="$TMP_ROOT/s7-snooze"
new_store "$S7_DIR"
S7_FILE="$(add_wakeup "$S7_DIR" --due 2026-09-02 --person aiko-tanaka --why "snoozeme" --origin user-ask)"

s7_out="$("$QUEUE" "$S7_DIR" snooze 2026-09-02-aiko-tanaka --days 7 --today 2026-09-02 2>&1)"
s7_status=$?
if [ "$s7_status" -eq 0 ] && grep -q '^due: 2026-09-09$' "$S7_FILE" && grep -q '^status: pending$' "$S7_FILE" && grep -q '^snooze-count: 1$' "$S7_FILE"; then
  pass "snooze: due-forward, status pending, snooze-count 1"
else
  fail "snooze: unexpected result (status=$s7_status): $(cat "$S7_FILE")"
fi

if grep -q '^schema_version: 1.1.0$' "$S7_FILE"; then
  pass "snooze: 1.0.0 file upgraded to schema_version 1.1.0"
else
  fail "snooze: schema_version not upgraded: $(grep schema_version "$S7_FILE")"
fi

s7_after_source_signal="$(awk '/^source-signal:/{f=1; next} f{print; c++} c==5{exit}' "$S7_FILE")"
s7_expected_order="$(printf 'fired-on:\ndismiss-reason:\nacted-on:\nsnooze-count: 1\nsignal-type:')"
if [ "$s7_after_source_signal" = "$s7_expected_order" ]; then
  pass "snooze: upgrade inserts the five 1.1.0 fields in template order right after source-signal:"
else
  fail "snooze: field order mismatch after source-signal: got [$s7_after_source_signal] expected [$s7_expected_order]"
fi

"$QUEUE" "$S7_DIR" snooze 2026-09-02-aiko-tanaka --days 3 --today 2026-09-02 >/dev/null 2>&1
if grep -q '^snooze-count: 2$' "$S7_FILE"; then
  pass "snooze: second snooze increments snooze-count to 2"
else
  fail "snooze: second snooze did not increment snooze-count: $(grep snooze-count "$S7_FILE")"
fi

# fired-on preserved across fire -> snooze
S7B_DIR="$TMP_ROOT/s7b-fire-then-snooze"
new_store "$S7B_DIR"
S7B_FILE="$(add_wakeup "$S7B_DIR" --due 2026-09-02 --person aiko-tanaka --why "firesnooze" --origin user-ask)"
"$QUEUE" "$S7B_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z >/dev/null 2>&1
"$QUEUE" "$S7B_DIR" snooze 2026-09-02-aiko-tanaka --days 5 --today 2026-09-02 >/dev/null 2>&1
if grep -q '^fired-on: 2026-09-02$' "$S7B_FILE" && grep -q '^status: pending$' "$S7B_FILE"; then
  pass "snooze: fired-on preserved after a fire -> snooze"
else
  fail "snooze: fired-on not preserved after fire -> snooze: $(cat "$S7B_FILE")"
fi

# =============================================================================
# Scenario 8: dismiss
# =============================================================================

S8_DIR="$TMP_ROOT/s8-dismiss"
new_store "$S8_DIR"
S8_FILE="$(add_wakeup "$S8_DIR" --due 2026-09-02 --person aiko-tanaka --why "dismissme" --origin user-ask)"

s8_out="$("$QUEUE" "$S8_DIR" dismiss 2026-09-02-aiko-tanaka --reason not-now 2>&1)"
s8_status=$?
if [ "$s8_status" -eq 0 ] && grep -q '^status: dismissed$' "$S8_FILE" && grep -q '^dismiss-reason: not-now$' "$S8_FILE"; then
  pass "dismiss: valid reason sets status dismissed + dismiss-reason"
else
  fail "dismiss: unexpected result (status=$s8_status): $s8_out"
fi

S8B_DIR="$TMP_ROOT/s8b-dismiss-invalid"
new_store "$S8B_DIR"
S8B_FILE="$(add_wakeup "$S8B_DIR" --due 2026-09-02 --person aiko-tanaka --why "dismissbad" --origin user-ask)"
S8B_PRE="$TMP_ROOT/s8b-pre.md"
cp "$S8B_FILE" "$S8B_PRE"
"$QUEUE" "$S8B_DIR" dismiss 2026-09-02-aiko-tanaka --reason not-a-real-reason >/dev/null 2>&1
s8b_status=$?
s8b_diff="$(diff "$S8B_PRE" "$S8B_FILE" 2>&1)"
if [ "$s8b_status" -ne 0 ] && [ -z "$s8b_diff" ]; then
  pass "dismiss: invalid reason refused, file byte-identical"
else
  fail "dismiss: invalid reason not refused correctly (status=$s8b_status): $s8b_diff"
fi

"$QUEUE" "$S8_DIR" dismiss 2026-09-02-aiko-tanaka --reason already-handled >/dev/null 2>&1
s8c_status=$?
if [ "$s8c_status" -ne 0 ]; then
  pass "dismiss: dismissing an already-dismissed entry is refused"
else
  fail "dismiss: dismissing an already-dismissed entry should have exited non-zero"
fi

# =============================================================================
# Scenario 9: validate-store.sh clean after the lifecycle
# =============================================================================

for store in "$S2_DIR" "$S4_DIR" "$S6_DIR" "$S7_DIR" "$S7B_DIR" "$S8_DIR"; do
  s9_out="$("$VALIDATOR" "$store" 2>&1)"
  s9_status=$?
  if [ "$s9_status" -eq 0 ]; then
    pass "validate-store.sh clean after lifecycle: $store"
  else
    fail "validate-store.sh reported findings for $store: $s9_out"
  fi
done

# =============================================================================
# Scenario 10: event-proposal fires with kind + proposed_event
# =============================================================================

S10_DIR="$TMP_ROOT/s10-event-proposal"
new_store "$S10_DIR"
add_wakeup "$S10_DIR" --due 2026-09-02 --person aiko-tanaka --why "proposal" --origin user-ask \
  --kind event-proposal --event-title "Coffee with Aiko" \
  --event-start 2026-09-05T15:00:00Z --event-end 2026-09-05T15:30:00Z \
  --event-attendee aiko-tanaka >/dev/null

"$QUEUE" "$S10_DIR" fire --today 2026-09-02 --now 2026-09-02T14:00:00Z >/dev/null 2>&1
S10_BATCH_FILE="$(find "$S10_DIR/wakeups/fired" -type f -name '*.json' 2>/dev/null | head -n1)"
if [ -n "$S10_BATCH_FILE" ]; then
  s10_kind="$(jq -r '.entries[0].kind' "$S10_BATCH_FILE")"
  s10_title="$(jq -r '.entries[0].proposed_event.title' "$S10_BATCH_FILE")"
  if [ "$s10_kind" = "event-proposal" ] && [ "$s10_title" = "Coffee with Aiko" ] && [ "$s10_title" != "null" ]; then
    pass "event-proposal: batch entry carries kind: event-proposal and non-null proposed_event.title"
  else
    fail "event-proposal: batch entry mismatch: kind=$s10_kind title=$s10_title"
  fi
else
  fail "event-proposal: no batch file written"
fi

summary_and_exit
