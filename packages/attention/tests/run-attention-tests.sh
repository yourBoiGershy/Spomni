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
  # signals/feedback.jsonl is excluded: a feedback-ledger append is outcome
  # recording (plan 34 D1), not a signal to anyone -- the silent-decline
  # doctrine covers wake-ups/interactions/people/calendar file listings only.
  S2_FILES_BEFORE="$(find "$S2_DIR" -type f | grep -v "/signals/feedback.jsonl\$" | sort)"

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

  S2_FILES_AFTER="$(find "$S2_DIR" -type f | grep -v "/signals/feedback.jsonl\$" | sort)"
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

# =============================================================================
# Scenarios 4-10: calibrate.sh --seed-from-user-model and --rescale
# (packages/attention/specs/calibration.md "Seeding from user-model" /
# "Rescale"), against packages/attention/tests/fixtures/calibration-seed/.
#
# All runs pin --today 2026-08-30 for determinism; `generated_at` is still
# wall-clock (calibrate.sh does not let --today override it), so comparisons
# against expected-*.json normalize it away with `jq -S 'del(.generated_at)'`
# and separately assert it looks like a real UTC timestamp.
# =============================================================================

CALIBRATE="$REPO_ROOT/packages/attention/scripts/calibrate.sh"
SEED_FIXTURES="$REPO_ROOT/packages/attention/tests/fixtures/calibration-seed"

if [ ! -x "$CALIBRATE" ]; then
  fail "calibrate.sh missing or not executable at $CALIBRATE"
else

# --- fixture-normalized-diff helper: strip the non-deterministic
#     generated_at field via jq -S before diffing two ranking-weights.json
#     files (key order in the file is otherwise deterministic since
#     calibrate.sh writes via `jq -S`). ---
normalized_diff() {
  # $1 = expected path, $2 = actual path
  diff <(jq -S 'del(.generated_at)' "$1") <(jq -S 'del(.generated_at)' "$2") 2>&1
}

assert_generated_at_is_utc_timestamp() {
  # $1 = description, $2 = ranking-weights.json path
  if jq -e '.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$2" >/dev/null 2>&1; then
    pass "$1: generated_at is a UTC timestamp"
  else
    fail "$1: generated_at is not a UTC timestamp: $(jq -r '.generated_at' "$2" 2>&1)"
  fi
}

# =============================================================================
# Scenario 4: seed on a confirmed user-model -> byte-equals (mod generated_at)
# the hand-derived expected-seeded.json
# =============================================================================

S4_DIR="$TMP_ROOT/s4-seed-confirmed"
mkdir -p "$S4_DIR"
cp "$SEED_FIXTURES/user-model.md" "$S4_DIR/user-model.md"
cp "$SEED_FIXTURES/ranking-weights.before.json" "$S4_DIR/ranking-weights.json"

s4_output="$("$CALIBRATE" "$S4_DIR" --seed-from-user-model --today 2026-08-30 2>&1)"
s4_status=$?

if [ "$s4_status" -eq 0 ]; then
  pass "seed on confirmed user-model exits 0"
else
  fail "seed on confirmed user-model exited $s4_status (expected 0): $s4_output"
fi

s4_diff="$(normalized_diff "$SEED_FIXTURES/expected-seeded.json" "$S4_DIR/ranking-weights.json")"
if [ -z "$s4_diff" ]; then
  pass "seed on confirmed user-model matches expected-seeded.json (mod generated_at)"
else
  fail "seed on confirmed user-model did not match expected-seeded.json:"
  echo "$s4_diff"
fi

assert_generated_at_is_utc_timestamp "seed on confirmed user-model" "$S4_DIR/ranking-weights.json"

# =============================================================================
# Scenario 5: seed on a draft user-model -> refuses exit 3, no file touch
# =============================================================================

S5_DIR="$TMP_ROOT/s5-seed-draft"
mkdir -p "$S5_DIR"
cp "$SEED_FIXTURES/user-model.draft.md" "$S5_DIR/user-model.md"
cp "$SEED_FIXTURES/ranking-weights.before.json" "$S5_DIR/ranking-weights.json"
S5_PRE="$TMP_ROOT/s5-pre-image.json"
cp "$S5_DIR/ranking-weights.json" "$S5_PRE"

s5_output="$("$CALIBRATE" "$S5_DIR" --seed-from-user-model --today 2026-08-30 2>&1)"
s5_status=$?

if [ "$s5_status" -eq 3 ]; then
  pass "seed on a draft user-model refuses with exit 3"
else
  fail "seed on a draft user-model exited $s5_status (expected 3): $s5_output"
fi

s5_diff="$(diff "$S5_PRE" "$S5_DIR/ranking-weights.json" 2>&1)"
if [ -z "$s5_diff" ]; then
  pass "seed on a draft user-model leaves ranking-weights.json byte-identical"
else
  fail "seed on a draft user-model touched ranking-weights.json:"
  echo "$s5_diff"
fi

# =============================================================================
# Scenario 5b: seed on a provisional user-model -> exits 0, writes
# ranking-weights.json byte-identical (mod generated_at) to the confirmed
# case's expected-seeded.json (plan 31 D6 — a provisional model still seeds)
# =============================================================================

S5B_DIR="$TMP_ROOT/s5b-seed-provisional"
mkdir -p "$S5B_DIR"
cp "$SEED_FIXTURES/user-model.provisional.md" "$S5B_DIR/user-model.md"
cp "$SEED_FIXTURES/ranking-weights.before.json" "$S5B_DIR/ranking-weights.json"

s5b_output="$("$CALIBRATE" "$S5B_DIR" --seed-from-user-model --today 2026-08-30 2>&1)"
s5b_status=$?

if [ "$s5b_status" -eq 0 ]; then
  pass "seed on a provisional user-model exits 0"
else
  fail "seed on a provisional user-model exited $s5b_status (expected 0): $s5b_output"
fi

s5b_diff="$(normalized_diff "$SEED_FIXTURES/expected-seeded.json" "$S5B_DIR/ranking-weights.json")"
if [ -z "$s5b_diff" ]; then
  pass "seed on a provisional user-model matches expected-seeded.json (mod generated_at), same as confirmed"
else
  fail "seed on a provisional user-model did not match expected-seeded.json:"
  echo "$s5b_diff"
fi

# =============================================================================
# Scenario 6: signal-types/tags are never touched by seed mode
# =============================================================================

s6_sig="$(jq -S '.weights["signal-types"]' "$S4_DIR/ranking-weights.json")"
s6_sig_expected="$(jq -S '.weights["signal-types"]' "$SEED_FIXTURES/ranking-weights.before.json")"
s6_tags="$(jq -S '.weights.tags' "$S4_DIR/ranking-weights.json")"
s6_tags_expected="$(jq -S '.weights.tags' "$SEED_FIXTURES/ranking-weights.before.json")"

if [ "$s6_sig" = "$s6_sig_expected" ] && [ "$s6_tags" = "$s6_tags_expected" ]; then
  pass "seed mode leaves signal-types/tags untouched"
else
  fail "seed mode touched signal-types/tags (should never write them)"
fi

# =============================================================================
# Scenario 7: revision-aware re-seed — bumped revision re-seeds
# rationale-matched keys (friend et al.) but leaves a user-tuned key
# (kinds.professional, whose rationale doesn't match the seed pattern) alone
# =============================================================================

S7_DIR="$TMP_ROOT/s7-reseed"
mkdir -p "$S7_DIR"
cp "$SEED_FIXTURES/user-model.revision2.md" "$S7_DIR/user-model.md"
cp "$SEED_FIXTURES/ranking-weights.reseed-before.json" "$S7_DIR/ranking-weights.json"

s7_output="$("$CALIBRATE" "$S7_DIR" --seed-from-user-model --today 2026-08-30 2>&1)"
s7_status=$?

if [ "$s7_status" -eq 0 ]; then
  pass "re-seed against a bumped revision exits 0"
else
  fail "re-seed against a bumped revision exited $s7_status (expected 0): $s7_output"
fi

s7_friend_rationale="$(jq -r '.weights.kinds.friend.rationale' "$S7_DIR/ranking-weights.json")"
s7_friend_weight="$(jq -r '.weights.kinds.friend.weight' "$S7_DIR/ranking-weights.json")"
if [ "$s7_friend_rationale" = "seeded from user-model revision 2" ] && [ "$s7_friend_weight" = "1.2" ]; then
  pass "re-seed rewrites a rationale-matched key (kinds.friend) to the new revision"
else
  fail "re-seed did not rewrite kinds.friend as expected (rationale='$s7_friend_rationale' weight='$s7_friend_weight')"
fi

s7_prof_rationale="$(jq -r '.weights.kinds.professional.rationale' "$S7_DIR/ranking-weights.json")"
s7_prof_weight="$(jq -r '.weights.kinds.professional.weight' "$S7_DIR/ranking-weights.json")"
s7_prof_updated="$(jq -r '.weights.kinds.professional.updated' "$S7_DIR/ranking-weights.json")"
if [ "$s7_prof_rationale" = "acted on 6 of 7 fired nudges" ] && [ "$s7_prof_weight" = "1.4" ] && [ "$s7_prof_updated" = "2026-08-15" ]; then
  pass "re-seed leaves a user-tuned key (kinds.professional) untouched"
else
  fail "re-seed clobbered the user-tuned kinds.professional entry (rationale='$s7_prof_rationale' weight='$s7_prof_weight' updated='$s7_prof_updated')"
fi

# =============================================================================
# Scenario 8: rescale clamp — an entry that would land outside [0.25, 2.0]
# after the geometric-mean divide is clamped to the bound
# =============================================================================

S8_DIR="$TMP_ROOT/s8-rescale-clamp"
mkdir -p "$S8_DIR"
cp "$SEED_FIXTURES/ranking-weights.rescale-clamp.json" "$S8_DIR/ranking-weights.json"

s8_output="$("$CALIBRATE" "$S8_DIR" --rescale evidence --today 2026-08-30 2>&1)"
s8_status=$?

if [ "$s8_status" -eq 0 ]; then
  pass "rescale with clamp-triggering inputs exits 0"
else
  fail "rescale with clamp-triggering inputs exited $s8_status (expected 0): $s8_output"
fi

s8_meeting="$(jq -r '.weights.evidence.meeting.weight' "$S8_DIR/ranking-weights.json")"
s8_co="$(jq -r '.weights.evidence.co_attended.weight' "$S8_DIR/ranking-weights.json")"
s8_chat="$(jq -r '.weights.evidence.chat_day.weight' "$S8_DIR/ranking-weights.json")"
if [ "$s8_meeting" = "2" ] && [ "$s8_co" = "2" ] && [ "$s8_chat" = "0.25" ]; then
  pass "rescale clamps out-of-bound post-divide weights to [0.25, 2.0] (meeting=2, co_attended=2, chat_day=0.25)"
else
  fail "rescale clamp mismatch (meeting=$s8_meeting co_attended=$s8_co chat_day=$s8_chat, expected 2/2/0.25)"
fi

s8_out_of_bounds="$(jq '[.weights.evidence[].weight | select(. > 2.0 or . < 0.25)] | length' "$S8_DIR/ranking-weights.json")"
if [ "$s8_out_of_bounds" = "0" ]; then
  pass "rescale never leaves any entry outside [0.25, 2.0]"
else
  fail "rescale left $s8_out_of_bounds entry/entries outside [0.25, 2.0]"
fi

# =============================================================================
# Scenario 9: rescale kinds — geometric mean lands at 1.0, ratios preserved,
# rationale/updated stamped on every entry, other dimensions untouched, and a
# second run is a no-op
# =============================================================================

S9_DIR="$TMP_ROOT/s9-rescale-kinds"
mkdir -p "$S9_DIR"
cp "$SEED_FIXTURES/ranking-weights.rescale-kinds.json" "$S9_DIR/ranking-weights.json"
S9_SIG_BEFORE="$(jq -S '.weights["signal-types"]' "$S9_DIR/ranking-weights.json")"
S9_TAGS_BEFORE="$(jq -S '.weights.tags' "$S9_DIR/ranking-weights.json")"
S9_EVIDENCE_BEFORE="$(jq -S '.weights.evidence' "$S9_DIR/ranking-weights.json")"

s9_output="$("$CALIBRATE" "$S9_DIR" --rescale kinds --today 2026-08-30 2>&1)"
s9_status=$?

if [ "$s9_status" -eq 0 ]; then
  pass "rescale kinds exits 0"
else
  fail "rescale kinds exited $s9_status (expected 0): $s9_output"
fi

s9_geomean_diff="$(jq -r '
  (.weights.kinds | to_entries | map(.value.weight) ) as $ws
  | ($ws | length) as $n
  | (($ws | map(log) | add / $n) | exp) as $gm
  | (($gm - 1.0) | if . < 0 then -. else . end)
' "$S9_DIR/ranking-weights.json")"
s9_geomean_ok="$(awk -v d="$s9_geomean_diff" 'BEGIN { print (d <= 0.01) ? "1" : "0" }')"
if [ "$s9_geomean_ok" = "1" ]; then
  pass "rescale kinds: result's geometric mean is within 0.01 of 1.0 (diff=$s9_geomean_diff)"
else
  fail "rescale kinds: result's geometric mean is off by $s9_geomean_diff (expected <= 0.01)"
fi

# ratio checks: friend/family were equal (1.6/1.6) and collaborator/professional
# was 0.8/1.2 = 0.6667 before rescale — both ratios must survive the divide.
s9_friend="$(jq -r '.weights.kinds.friend.weight' "$S9_DIR/ranking-weights.json")"
s9_family="$(jq -r '.weights.kinds.family.weight' "$S9_DIR/ranking-weights.json")"
s9_collab="$(jq -r '.weights.kinds.collaborator.weight' "$S9_DIR/ranking-weights.json")"
s9_prof="$(jq -r '.weights.kinds.professional.weight' "$S9_DIR/ranking-weights.json")"
s9_ratio1_ok="$(awk -v a="$s9_friend" -v b="$s9_family" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d <= 0.01) ? "1" : "0" }')"
s9_ratio2_ok="$(awk -v a="$s9_collab" -v b="$s9_prof" -v want="0.6667" 'BEGIN { r = a / b; d = r - want; if (d < 0) d = -d; print (d <= 0.01) ? "1" : "0" }')"
if [ "$s9_ratio1_ok" = "1" ] && [ "$s9_ratio2_ok" = "1" ]; then
  pass "rescale kinds preserves pairwise ratios (friend==family, collaborator:professional≈0.667)"
else
  fail "rescale kinds did not preserve ratios (friend=$s9_friend family=$s9_family collaborator=$s9_collab professional=$s9_prof)"
fi

s9_rationale_mismatches="$(jq -r '[.weights.kinds[] | select(.rationale | test("^rescaled 2026-08-30: dimension mean [0-9.]+ → 1\\.0$") | not)] | length' "$S9_DIR/ranking-weights.json")"
s9_updated_mismatches="$(jq -r '[.weights.kinds[] | select(.updated != "2026-08-30")] | length' "$S9_DIR/ranking-weights.json")"
if [ "$s9_rationale_mismatches" = "0" ] && [ "$s9_updated_mismatches" = "0" ]; then
  pass "rescale kinds stamps every entry's rationale/updated"
else
  fail "rescale kinds left $s9_rationale_mismatches entries with a bad rationale and $s9_updated_mismatches with a stale updated"
fi

S9_SIG_AFTER="$(jq -S '.weights["signal-types"]' "$S9_DIR/ranking-weights.json")"
S9_TAGS_AFTER="$(jq -S '.weights.tags' "$S9_DIR/ranking-weights.json")"
S9_EVIDENCE_AFTER="$(jq -S '.weights.evidence' "$S9_DIR/ranking-weights.json")"
if [ "$S9_SIG_BEFORE" = "$S9_SIG_AFTER" ] && [ "$S9_TAGS_BEFORE" = "$S9_TAGS_AFTER" ] && [ "$S9_EVIDENCE_BEFORE" = "$S9_EVIDENCE_AFTER" ]; then
  pass "rescale kinds leaves signal-types/tags/evidence untouched"
else
  fail "rescale kinds touched a dimension other than kinds"
fi

S9_POST_FIRST="$TMP_ROOT/s9-post-first.json"
cp "$S9_DIR/ranking-weights.json" "$S9_POST_FIRST"

s9b_output="$("$CALIBRATE" "$S9_DIR" --rescale kinds --today 2026-08-30 2>&1)"
s9b_status=$?
s9b_diff="$(diff "$S9_POST_FIRST" "$S9_DIR/ranking-weights.json" 2>&1)"
if [ "$s9b_status" -eq 0 ] && [ -z "$s9b_diff" ]; then
  pass "a second rescale kinds run (already near mean 1.0) is a no-op"
else
  fail "a second rescale kinds run was not a no-op (status=$s9b_status):"
  echo "$s9b_diff"
fi

# =============================================================================
# Scenario 10: sabotage proof — a broken revision-aware re-seed check (always
# re-seeds, never checking the prior rationale's revision number) IS caught by
# scenario 7's user-tuned-entry assertion. Demonstrates the assertion has
# teeth; not counted as a real regression in this script (the sabotaged copy
# is thrown away after).
# =============================================================================

S10_SABOTAGE="$TMP_ROOT/calibrate-sabotage.sh"
cp "$CALIBRATE" "$S10_SABOTAGE"
chmod +x "$S10_SABOTAGE"
sed -i.bak 's/if (\$cap != null) and ((\$cap.n | tonumber) < \$revision) then/if true then/' "$S10_SABOTAGE"

if grep -q 'if true then' "$S10_SABOTAGE" && ! grep -q '\$cap != null' "$S10_SABOTAGE"; then
  pass "sabotage proof: revision-aware re-seed check patched out of the sabotaged copy"
else
  fail "sabotage proof setup: sed did not patch the re-seed check as expected"
fi

S10_DIR="$TMP_ROOT/s10-sabotage-run"
mkdir -p "$S10_DIR"
cp "$SEED_FIXTURES/user-model.revision2.md" "$S10_DIR/user-model.md"
cp "$SEED_FIXTURES/ranking-weights.reseed-before.json" "$S10_DIR/ranking-weights.json"
"$S10_SABOTAGE" "$S10_DIR" --seed-from-user-model --today 2026-08-30 >/dev/null 2>&1

s10_prof_rationale="$(jq -r '.weights.kinds.professional.rationale' "$S10_DIR/ranking-weights.json")"
if [ "$s10_prof_rationale" != "acted on 6 of 7 fired nudges" ]; then
  echo "FAIL (expected): sabotaged calibrate.sh clobbered the user-tuned kinds.professional entry (rationale is now '$s10_prof_rationale')"
  pass "sabotage proof: scenario 7's user-tuned-entry assertion would catch a broken revision-aware re-seed check"
else
  fail "sabotage proof: the sabotaged copy did NOT clobber kinds.professional — sed patch had no effect, sabotage proof is void"
fi

fi # calibrate.sh executable guard

summary_and_exit
