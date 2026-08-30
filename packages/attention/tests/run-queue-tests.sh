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
#   11. acted-on sweep (specs/outcome-recording.md): matching interaction
#      inside the window -> true; open window with no match -> untouched +
#      silent; closed window with no match -> false; re-run -> silent and
#      byte-identical
#   12. feedback ledger (plan 34 D1, outcome-recording.md): every lifecycle op
#      (snooze/dismiss/confirm/decline/acted-on) appends one feedback-event
#      line to <store>/signals/feedback.jsonl via ingestion's
#      feedback-file.sh; --text/--channel/--source passthrough on dismiss;
#      missing signals/ dir still gets created; absent feedback-file.sh
#      prints a skip line and does not block the lifecycle write
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
PERSON_FIXTURE_2="$REPO_ROOT/packages/core/fixtures/store/people/ayesha-malik.md"
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

for req in "$QUEUE" "$WAKEUP_ADD" "$VALIDATOR" "$PERSON_FIXTURE" "$PERSON_FIXTURE_2" "$WEEK_PLAN_FIXTURE" "$INBOX_FIXTURE"; do
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

# =============================================================================
# Scenario 11: acted-on sweep
# =============================================================================

S11_DIR="$TMP_ROOT/s11-acted-on"
mkdir -p "$S11_DIR/people" "$S11_DIR/interactions" "$S11_DIR/wakeups"
cp "$PERSON_FIXTURE" "$S11_DIR/people/"
cp "$PERSON_FIXTURE_2" "$S11_DIR/people/"

# A: fires 2026-09-01 (window (09-01, 09-08]); a matching interaction lands
#    inside the window -> should resolve to acted-on: true.
S11_A_FILE="$(add_wakeup "$S11_DIR" --due 2026-09-01 --person aiko-tanaka --why "acted-a" --origin user-ask)"
# B: fires 2026-09-01 too, same window, but no interaction ever mentions
#    ayesha-malik -> should stay untouched (window still open on 2026-09-03).
S11_B_FILE="$(add_wakeup "$S11_DIR" --due 2026-09-01 --person ayesha-malik --why "acted-b" --origin user-ask)"
# C: fires 2026-08-20 (window (08-20, 08-27]); no interaction, and by
#    2026-09-03 the window is long closed -> should resolve to acted-on: false.
S11_C_FILE="$(add_wakeup "$S11_DIR" --due 2026-08-20 --person aiko-tanaka --why "acted-c" --origin user-ask)"

"$QUEUE" "$S11_DIR" fire --today 2026-08-20 --now 2026-08-20T14:00:00Z >/dev/null 2>&1
"$QUEUE" "$S11_DIR" fire --today 2026-09-01 --now 2026-09-01T14:00:00Z >/dev/null 2>&1

if grep -q '^fired-on: 2026-08-20$' "$S11_C_FILE" && grep -q '^fired-on: 2026-09-01$' "$S11_A_FILE" \
  && grep -q '^fired-on: 2026-09-01$' "$S11_B_FILE"; then
  pass "acted-on: setup fired A/B/C with the expected fired-on dates"
else
  fail "acted-on: setup did not fire A/B/C as expected"
fi

# interaction matching A only (people: aiko-tanaka), dated inside A's window
S11_INTERACTION="$S11_DIR/interactions/2026-09-03-aiko-tanaka.md"
{
  echo "---"
  echo "schema_version: 1.0.0"
  echo "date: 2026-09-03"
  echo "people: [\"[[aiko-tanaka]]\"]"
  echo "calendar-event: null"
  echo "source-capture: null"
  echo "---"
  echo ""
  echo "## Summary"
  echo ""
  echo "Caught up with Aiko."
  echo ""
  echo "## Commitments"
  echo ""
  echo "- _none_"
} > "$S11_INTERACTION"

s11_out="$("$QUEUE" "$S11_DIR" acted-on --today 2026-09-03 2>&1)"
s11_status=$?

if [ "$s11_status" -eq 0 ]; then
  pass "acted-on: sweep exits 0"
else
  fail "acted-on: sweep exited $s11_status: $s11_out"
fi

S11_A_ID="2026-09-01-aiko-tanaka"
S11_B_ID="2026-09-01-ayesha-malik"
S11_C_ID="2026-08-20-aiko-tanaka"

if printf '%s\n' "$s11_out" | grep -qx "acted-on ${S11_A_ID} -> true"; then
  pass "acted-on: matching interaction inside the window -> true, printed"
else
  fail "acted-on: expected 'acted-on ${S11_A_ID} -> true' in output: $s11_out"
fi

if printf '%s\n' "$s11_out" | grep -qx "acted-on ${S11_C_ID} -> false"; then
  pass "acted-on: no match + closed window -> false, printed"
else
  fail "acted-on: expected 'acted-on ${S11_C_ID} -> false' in output: $s11_out"
fi

if printf '%s\n' "$s11_out" | grep -q "${S11_B_ID}"; then
  fail "acted-on: open-window no-match entry B should not appear in output: $s11_out"
else
  pass "acted-on: open-window no-match entry B silent (no output line)"
fi

if grep -q '^acted-on: true$' "$S11_A_FILE"; then
  pass "acted-on: A's file carries acted-on: true"
else
  fail "acted-on: A's file missing acted-on: true: $(grep acted-on "$S11_A_FILE")"
fi

if grep -qx 'acted-on:' "$S11_B_FILE"; then
  pass "acted-on: B's file left untouched (acted-on still null)"
else
  fail "acted-on: B's file was modified: $(grep acted-on "$S11_B_FILE")"
fi

if grep -q '^acted-on: false$' "$S11_C_FILE"; then
  pass "acted-on: C's file carries acted-on: false"
else
  fail "acted-on: C's file missing acted-on: false: $(grep acted-on "$S11_C_FILE")"
fi

# re-run: idempotent — A and C are already resolved (skipped), B's window is
# still open on 2026-09-03 -> still untouched. Whole store must be silent and
# byte-identical.
S11_SNAPSHOT="$TMP_ROOT/s11-snapshot"
cp -R "$S11_DIR" "$S11_SNAPSHOT"

s11b_out="$("$QUEUE" "$S11_DIR" acted-on --today 2026-09-03 2>&1)"
s11b_status=$?

if [ "$s11b_status" -eq 0 ] && [ -z "$s11b_out" ]; then
  pass "acted-on: re-run is silent"
else
  fail "acted-on: re-run was not silent (status=$s11b_status): $s11b_out"
fi

s11b_diff="$(diff -r "$S11_SNAPSHOT" "$S11_DIR" 2>&1)"
if [ -z "$s11b_diff" ]; then
  pass "acted-on: re-run leaves the store byte-identical"
else
  fail "acted-on: re-run changed the store:"
  echo "$s11b_diff"
fi

s11_validate_out="$("$VALIDATOR" "$S11_DIR" 2>&1)"
s11_validate_status=$?
if [ "$s11_validate_status" -eq 0 ]; then
  pass "validate-store.sh clean after the acted-on sweep"
else
  fail "validate-store.sh reported findings after the acted-on sweep: $s11_validate_out"
fi

# =============================================================================
# Scenario 12: feedback ledger (plan 34 D1) — every lifecycle op appends one
# feedback-event line to <store>/signals/feedback.jsonl via
# ../../ingestion/scripts/feedback-file.sh.
# =============================================================================

s12_line_for() {
  # s12_line_for <target-id> — last ledger line whose target matches
  target="$1"
  jq -c "select(.target == \"wakeup:${target}\")" "$S12_LEDGER" 2>/dev/null | tail -n1
}

S12_DIR="$TMP_ROOT/s12-feedback"
mkdir -p "$S12_DIR/people" "$S12_DIR/interactions" "$S12_DIR/wakeups"
cp "$PERSON_FIXTURE" "$S12_DIR/people/"
cp "$PERSON_FIXTURE_2" "$S12_DIR/people/"
S12_LEDGER="$S12_DIR/signals/feedback.jsonl"

S12_SNOOZE_FILE="$(add_wakeup "$S12_DIR" --due 2026-09-10 --person aiko-tanaka --why "snooze" --origin user-ask)"
S12_DISMISS_FILE="$(add_wakeup "$S12_DIR" --due 2026-09-11 --person aiko-tanaka --why "dismiss" --origin user-ask)"
S12_DISMISS_TEXT_FILE="$(add_wakeup "$S12_DIR" --due 2026-09-12 --person aiko-tanaka --why "dismiss-text" --origin user-ask)"
S12_CONFIRM_FILE="$(add_wakeup "$S12_DIR" --due 2026-09-13 --person aiko-tanaka --why "confirm" --origin user-ask \
  --kind event-proposal --event-title "Coffee" --event-start 2026-09-13T15:00:00Z --event-end 2026-09-13T15:30:00Z \
  --event-attendee aiko-tanaka)"
S12_DECLINE_FILE="$(add_wakeup "$S12_DIR" --due 2026-09-14 --person aiko-tanaka --why "decline" --origin user-ask \
  --kind event-proposal --event-title "Lunch" --event-start 2026-09-14T15:00:00Z --event-end 2026-09-14T15:30:00Z \
  --event-attendee aiko-tanaka)"
S12_MATCH_FILE="$(add_wakeup "$S12_DIR" --due 2026-08-20 --person aiko-tanaka --why "acted-match" --origin user-ask)"
S12_NOMATCH_FILE="$(add_wakeup "$S12_DIR" --due 2026-08-01 --person ayesha-malik --why "acted-nomatch" --origin user-ask)"

S12_SNOOZE_ID="2026-09-10-aiko-tanaka"
S12_DISMISS_ID="2026-09-11-aiko-tanaka"
S12_DISMISS_TEXT_ID="2026-09-12-aiko-tanaka"
S12_CONFIRM_ID="2026-09-13-aiko-tanaka"
S12_DECLINE_ID="2026-09-14-aiko-tanaka"
S12_MATCH_ID="2026-08-20-aiko-tanaka"
S12_NOMATCH_ID="2026-08-01-ayesha-malik"

# fire the acted-on candidates on their own due dates so fired-on anchors
# correctly (mirrors scenario 11)
"$QUEUE" "$S12_DIR" fire --today 2026-08-01 --now 2026-08-01T14:00:00Z >/dev/null 2>&1
"$QUEUE" "$S12_DIR" fire --today 2026-08-20 --now 2026-08-20T14:00:00Z >/dev/null 2>&1

# matching interaction for S12_MATCH_ID, dated inside its (fired-on, +7d] window
S12_INTERACTION="$S12_DIR/interactions/2026-08-25-aiko-tanaka.md"
{
  echo "---"
  echo "schema_version: 1.0.0"
  echo "date: 2026-08-25"
  echo "people: [\"[[aiko-tanaka]]\"]"
  echo "calendar-event: null"
  echo "source-capture: null"
  echo "---"
  echo ""
  echo "## Summary"
  echo ""
  echo "Caught up with Aiko."
  echo ""
  echo "## Commitments"
  echo ""
  echo "- _none_"
} > "$S12_INTERACTION"

"$QUEUE" "$S12_DIR" snooze "$S12_SNOOZE_ID" --days 7 --today 2026-09-10 >/dev/null 2>&1
"$QUEUE" "$S12_DIR" dismiss "$S12_DISMISS_ID" --reason not-now >/dev/null 2>&1
"$QUEUE" "$S12_DIR" dismiss "$S12_DISMISS_TEXT_ID" --reason not-now --text "not now thanks" --channel beeper-self --source reply >/dev/null 2>&1
"$QUEUE" "$S12_DIR" confirm "$S12_CONFIRM_ID" --event-id evt-1 >/dev/null 2>&1
"$QUEUE" "$S12_DIR" decline "$S12_DECLINE_ID" --reason not-now >/dev/null 2>&1
"$QUEUE" "$S12_DIR" acted-on --today 2026-09-15 >/dev/null 2>&1

if [ -f "$S12_LEDGER" ]; then
  pass "feedback ledger: signals/feedback.jsonl created"
else
  fail "feedback ledger: signals/feedback.jsonl was not created"
fi

s12_snooze_line="$(s12_line_for "$S12_SNOOZE_ID")"
if [ "$(printf '%s' "$s12_snooze_line" | jq -r '.type')" = "snooze" ] \
  && [ "$(printf '%s' "$s12_snooze_line" | jq -r '.reason')" = "7d" ] \
  && [ "$(printf '%s' "$s12_snooze_line" | jq -r '.target')" = "wakeup:$S12_SNOOZE_ID" ]; then
  pass "feedback ledger: snooze --days 7 -> type snooze reason 7d"
else
  fail "feedback ledger: snooze line wrong: $s12_snooze_line"
fi

s12_dismiss_line="$(s12_line_for "$S12_DISMISS_ID")"
if [ "$(printf '%s' "$s12_dismiss_line" | jq -r '.type')" = "dismiss" ] \
  && [ "$(printf '%s' "$s12_dismiss_line" | jq -r '.reason')" = "not-now" ]; then
  pass "feedback ledger: dismiss --reason not-now -> type dismiss reason not-now"
else
  fail "feedback ledger: dismiss line wrong: $s12_dismiss_line"
fi

s12_confirm_line="$(s12_line_for "$S12_CONFIRM_ID")"
if [ "$(printf '%s' "$s12_confirm_line" | jq -r '.type')" = "acted-on" ] \
  && [ "$(printf '%s' "$s12_confirm_line" | jq -r '.reason')" = "confirmed" ]; then
  pass "feedback ledger: confirm -> type acted-on reason confirmed"
else
  fail "feedback ledger: confirm line wrong: $s12_confirm_line"
fi

s12_decline_line="$(s12_line_for "$S12_DECLINE_ID")"
if [ "$(printf '%s' "$s12_decline_line" | jq -r '.type')" = "dismiss" ] \
  && [ "$(printf '%s' "$s12_decline_line" | jq -r '.reason')" = "not-now" ]; then
  pass "feedback ledger: decline --reason not-now -> type dismiss reason not-now"
else
  fail "feedback ledger: decline line wrong: $s12_decline_line"
fi

s12_acted_lines="$(jq -c "select(.target == \"wakeup:${S12_MATCH_ID}\" and .type == \"acted-on\" and .source == \"auto\")" "$S12_LEDGER" 2>/dev/null)"
s12_acted_count="$(printf '%s\n' "$s12_acted_lines" | grep -c . || true)"
if [ "$s12_acted_count" = "1" ]; then
  pass "feedback ledger: acted-on sweep auto-match -> exactly one acted-on/auto line"
else
  fail "feedback ledger: expected exactly one acted-on/auto line, got $s12_acted_count: $s12_acted_lines"
fi

s12_nomatch_lines="$(jq -c "select(.target == \"wakeup:${S12_NOMATCH_ID}\")" "$S12_LEDGER" 2>/dev/null)"
if [ -z "$s12_nomatch_lines" ]; then
  pass "feedback ledger: acted-on sweep closed-window no-match writes no ledger line"
else
  fail "feedback ledger: unexpected ledger line for no-match entry: $s12_nomatch_lines"
fi

s12_all_target_count="$(jq -r '.target' "$S12_LEDGER" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s12_all_target_count" = "6" ]; then
  pass "feedback ledger: exactly six lines written across all ops (5 lifecycle ops + the text-dismiss case)"
else
  fail "feedback ledger: expected 6 total ledger lines, got $s12_all_target_count"
fi

s12_text_line="$(s12_line_for "$S12_DISMISS_TEXT_ID")"
if [ "$(printf '%s' "$s12_text_line" | jq -r '.text')" = "not now thanks" ] \
  && [ "$(printf '%s' "$s12_text_line" | jq -r '.channel')" = "beeper-self" ] \
  && [ "$(printf '%s' "$s12_text_line" | jq -r '.source')" = "reply" ]; then
  pass "feedback ledger: dismiss --text/--channel/--source reply carried verbatim"
else
  fail "feedback ledger: text-dismiss line wrong: $s12_text_line"
fi

# --- fixture store without signals/ dir: op still exits 0 and creates it ---

S12B_DIR="$TMP_ROOT/s12b-no-signals"
new_store "$S12B_DIR"
add_wakeup "$S12B_DIR" --due 2026-09-02 --person aiko-tanaka --why "nosignals" --origin user-ask >/dev/null

if [ -d "$S12B_DIR/signals" ]; then
  fail "feedback ledger (no-signals setup): signals/ unexpectedly pre-existing"
else
  pass "feedback ledger (no-signals setup): signals/ absent before the op"
fi

s12b_out="$("$QUEUE" "$S12B_DIR" dismiss 2026-09-02-aiko-tanaka --reason not-now 2>&1)"
s12b_status=$?
if [ "$s12b_status" -eq 0 ] && [ -f "$S12B_DIR/signals/feedback.jsonl" ]; then
  pass "feedback ledger: dismiss on a store without signals/ creates the dir and exits 0"
else
  fail "feedback ledger: no-signals-dir case failed (status=$s12b_status): $s12b_out"
fi

# --- absent writer: no ingestion/scripts/feedback-file.sh sibling ---

S12C_ROOT="$TMP_ROOT/s12c-absent-writer"
mkdir -p "$S12C_ROOT/attention/scripts"
cp "$QUEUE" "$S12C_ROOT/attention/scripts/wakeup-queue.sh"
chmod +x "$S12C_ROOT/attention/scripts/wakeup-queue.sh"
S12C_STORE="$S12C_ROOT/store"
new_store "$S12C_STORE"
S12C_FILE="$(add_wakeup "$S12C_STORE" --due 2026-09-02 --person aiko-tanaka --why "absentwriter" --origin user-ask)"

s12c_out="$("$S12C_ROOT/attention/scripts/wakeup-queue.sh" "$S12C_STORE" dismiss 2026-09-02-aiko-tanaka --reason not-now 2>&1)"
s12c_status=$?
if [ "$s12c_status" -eq 0 ] && printf '%s\n' "$s12c_out" | grep -q '^feedback: skipped (feedback-file.sh absent)$'; then
  pass "feedback ledger: absent writer prints skip line and exits 0"
else
  fail "feedback ledger: absent-writer case failed (status=$s12c_status): $s12c_out"
fi

if grep -q '^status: dismissed$' "$S12C_FILE"; then
  pass "feedback ledger: absent writer still updates the wakeup file"
else
  fail "feedback ledger: absent writer did not update the wakeup file: $(cat "$S12C_FILE")"
fi

summary_and_exit
