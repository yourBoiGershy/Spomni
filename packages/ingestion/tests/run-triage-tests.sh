#!/usr/bin/env bash
# packages/ingestion/tests/run-triage-tests.sh
#
# Regression-locks packages/ingestion/scripts/triage-inbox.sh (plan 26 U6)
# against packages/ingestion/tests/fixtures/triage/, per plan 26 unit 10.
# Same style as run-seed-tests.sh: numbered assertions via pass()/fail(), a
# SUMMARY line, non-zero exit on any failure. bash 3.2 portable (no
# associative arrays, no mapfile).
#
# Fixture (packages/ingestion/tests/fixtures/triage/store/), all synthetic
# PII (invented names/emails/orgs — nothing from any real store):
#
#   inbox/hold-*.md        — one hold case per rule class (5 files), the
#     cold-pitch case's sender absent from index.json/people/ by
#     construction.
#   inbox/golden-*.md      — the zero-false-holds set: a voice-note
#     debrief, a multi-attendee calendar event, a genuine 1:1 email from a
#     known person, a noreply-*adjacent*-but-known-sender email (contains
#     "notifications" in the local part but not immediately before the
#     @-sign — the rule's \b(...)@last-instant boundary must not fire on
#     it), a non-invitation LinkedIn notification (post-like), and a
#     beeper chat-message.
#   inbox/quarantine/junk-noreply-marketing.md — a would-match junk event
#     placed under quarantine/, which the script must never descend into.
#   people/*.md, index.json — the two known contacts (Dana Whitfield,
#     Priya Nair) golden-known-email.md / golden-notifications-adjacent.md
#     resolve against; hold-cold-pitch.md's sender appears in neither.
#
# Timestamp normalization: triage-inbox.sh has no fixed-clock injection
# knob (it calls `date -u` directly), so per-rule ledger-line assertions
# below compare fields 1-2 (capture-id, rule-name) against a literal
# expected string and separately regex-validate field 3 is a well-formed
# ISO 8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`) — the cleaner of the two
# options given the script as built, since it needs no script changes and
# still pins the exact byte shape of fields 1-2 and the field-3 grammar.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TRIAGE="$REPO_ROOT/packages/ingestion/scripts/triage-inbox.sh"
FIXTURE_STORE="$REPO_ROOT/packages/ingestion/tests/fixtures/triage/store"

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

# --- script under test + fixtures must exist ---
if [ ! -x "$TRIAGE" ]; then
  echo "FAIL: $TRIAGE missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  echo "FAIL: fixture store missing at $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# A well-formed ISO 8601 UTC "held-at" timestamp, field 3 of a D3 line.
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# assert_ledger_line <file> <expected-id> <expected-rule> — asserts exactly
# one line in <file> starts with "<expected-id>\t<expected-rule>\t" and
# that its third field matches ISO_RE.
assert_ledger_line() {
  file="$1"
  id="$2"
  rule="$3"
  line="$(awk -F'\t' -v id="$id" -v rule="$rule" '$1 == id && $2 == rule { print; c++ } END { if (c != 1) exit 1 }' "$file" 2>/dev/null)"
  if [ -z "$line" ]; then
    fail "D3 ledger: expected exactly one '$id\t$rule\t<ts>' line in $(basename "$file"), found none/duplicate"
    return
  fi
  ts="$(printf '%s' "$line" | cut -f3)"
  if printf '%s' "$ts" | grep -Eq "$ISO_RE"; then
    pass "D3 ledger: $id -> $rule, field 3 '$ts' is a well-formed ISO 8601 UTC timestamp"
  else
    fail "D3 ledger: $id -> $rule, field 3 '$ts' is not a well-formed ISO 8601 UTC timestamp"
  fi
}

# =============================================================================
# Assertion group 1 — per-rule holds, one D3 ledger line each.
# =============================================================================

run1_data="$WORK_DIR/run1-data"
run1_out="$WORK_DIR/run1-out.txt"
run1_err="$WORK_DIR/run1-err.txt"

"$TRIAGE" "$FIXTURE_STORE" --data-dir "$run1_data" > "$run1_out" 2> "$run1_err"
run1_status=$?

if [ "$run1_status" -eq 0 ]; then
  pass "triage-inbox.sh: exits 0 against the fixture store"
else
  fail "triage-inbox.sh: exited $run1_status (expected 0): $(cat "$run1_err")"
fi

held_log="$run1_data/triage-held.log"
if [ -f "$held_log" ]; then
  pass "triage-held.log created under --data-dir on the first real run"
else
  fail "triage-held.log missing under --data-dir after the first real run"
fi

assert_ledger_line "$held_log" "hold-noreply-marketing" "noreply-marketing"
assert_ledger_line "$held_log" "hold-self-only-calendar" "self-only-calendar"
assert_ledger_line "$held_log" "hold-otp-security" "otp-security"
assert_ledger_line "$held_log" "hold-linkedin-invitation" "linkedin-invitation"
assert_ledger_line "$held_log" "hold-cold-pitch" "cold-pitch"

held_line_count="$(wc -l < "$held_log" | tr -d ' ')"
if [ "$held_line_count" = "5" ]; then
  pass "triage-held.log: exactly 5 lines after the first run (one per rule class, no extras)"
else
  fail "triage-held.log: expected exactly 5 lines, got $held_line_count"
fi

if grep -q '^triage: scanned=11 held=5 already-filed=0 already-held=0 per-rule=noreply-marketing:1,self-only-calendar:1,otp-security:1,linkedin-invitation:1,cold-pitch:1,noise-sender:0,calendar-ignore:0$' "$run1_out"; then
  pass "triage-inbox.sh: summary line matches exactly (scanned=11 held=5, one per rule)"
else
  fail "triage-inbox.sh: summary line mismatch — got: $(cat "$run1_out")"
fi

# =============================================================================
# Assertion group 2 — zero false-holds on the golden fall-through set.
# =============================================================================

golden_ids="golden-voice-note golden-multi-attendee golden-known-email golden-notifications-adjacent golden-linkedin-post-like golden-beeper-chat"

false_hold_found=0
for gid in $golden_ids; do
  if grep -q "^${gid}	" "$held_log"; then
    fail "zero-false-holds: golden fall-through case '$gid' was incorrectly held"
    false_hold_found=1
  fi
done
if [ "$false_hold_found" -eq 0 ]; then
  pass "zero-false-holds: all 6 golden fall-through cases (voice-note, multi-attendee calendar, known 1:1 email, notifications-adjacent-but-known sender, non-invitation LinkedIn notification, beeper chat-message) correctly unheld"
fi

# =============================================================================
# Assertion group 3 — idempotency: a second run appends zero lines.
# =============================================================================

run2_out="$WORK_DIR/run2-out.txt"
"$TRIAGE" "$FIXTURE_STORE" --data-dir "$run1_data" > "$run2_out" 2>/dev/null
run2_status=$?

held_line_count_2="$(wc -l < "$held_log" | tr -d ' ')"
if [ "$run2_status" -eq 0 ] && [ "$held_line_count_2" = "5" ]; then
  pass "idempotency: second real run against the same --data-dir appends zero lines (still 5)"
else
  fail "idempotency: second run exit=$run2_status, triage-held.log now has $held_line_count_2 lines (expected 0 exit, still 5)"
fi

if grep -q '^triage: scanned=11 held=0 already-filed=0 already-held=5 per-rule=noreply-marketing:0,self-only-calendar:0,otp-security:0,linkedin-invitation:0,cold-pitch:0,noise-sender:0,calendar-ignore:0$' "$run2_out"; then
  pass "idempotency: second run's summary line correctly reports held=0 already-held=5"
else
  fail "idempotency: second run summary line mismatch — got: $(cat "$run2_out")"
fi

# =============================================================================
# Assertion group 4 — --dry-run writes nothing.
# =============================================================================

dryrun_data="$WORK_DIR/dryrun-data"
dryrun_out="$WORK_DIR/dryrun-out.txt"
"$TRIAGE" "$FIXTURE_STORE" --data-dir "$dryrun_data" --dry-run > "$dryrun_out" 2>/dev/null
dryrun_status=$?

if [ "$dryrun_status" -eq 0 ]; then
  pass "--dry-run: exits 0"
else
  fail "--dry-run: exited $dryrun_status (expected 0)"
fi

if [ ! -e "$dryrun_data" ]; then
  pass "--dry-run: --data-dir directory itself was never created (tree-diff clean)"
else
  fail "--dry-run: --data-dir directory unexpectedly exists: $(find "$dryrun_data" -type f)"
fi

dryrun_held_count="$(grep -c '	' "$dryrun_out" 2>/dev/null || true)"
if [ "$dryrun_held_count" = "5" ]; then
  pass "--dry-run: prints exactly 5 would-be D3 lines to stdout (same 5 hold cases as the real run)"
else
  fail "--dry-run: expected 5 tab-bearing lines on stdout, got $dryrun_held_count"
fi

# =============================================================================
# Assertion group 5 — ledger is append-only: a pre-seeded line survives
# untouched and stays first.
# =============================================================================

preseed_data="$WORK_DIR/preseed-data"
mkdir -p "$preseed_data"
preseed_held="$preseed_data/triage-held.log"
preseed_line="$(printf 'legacy-hold-from-a-prior-run\tnoreply-marketing\t2020-01-01T00:00:00Z')"
printf '%s\n' "$preseed_line" > "$preseed_held"

"$TRIAGE" "$FIXTURE_STORE" --data-dir "$preseed_data" >/dev/null 2>&1

first_line_after="$(head -1 "$preseed_held")"
if [ "$first_line_after" = "$preseed_line" ]; then
  pass "append-only: the pre-seeded legacy line is untouched and still the first line after a run"
else
  fail "append-only: pre-seeded first line changed — expected '$preseed_line', got '$first_line_after'"
fi

preseed_total="$(wc -l < "$preseed_held" | tr -d ' ')"
if [ "$preseed_total" = "6" ]; then
  pass "append-only: pre-seeded line (1) + 5 new holds appended after it = 6 total lines"
else
  fail "append-only: expected 6 total lines (1 pre-seeded + 5 new), got $preseed_total"
fi

# =============================================================================
# Assertion group 6 — inbox/quarantine/ contents are ignored: neither held
# nor counted toward scanned. (Deliberate script behavior: it globs only
# <store-dir>/inbox/*.md, a non-recursive glob, so quarantine/ is never
# descended into and its file count never reaches "scanned" at all — not
# even as a skip. This assertion pins exactly that: quarantine's junk
# event is absent from the held ledger, and "scanned" equals the 11
# top-level inbox/*.md fixture files, not 12.)
# =============================================================================

if grep -q '^junk-noreply-marketing	' "$held_log"; then
  fail "quarantine: junk-noreply-marketing.md (under inbox/quarantine/) was incorrectly held"
else
  pass "quarantine: junk-noreply-marketing.md (under inbox/quarantine/) is not held (never scanned — non-recursive glob)"
fi

if grep -q 'scanned=11 ' "$run1_out"; then
  pass "quarantine: scanned=11 (the 11 top-level inbox/*.md fixtures only; the quarantined 12th file is not counted toward scanned either)"
else
  fail "quarantine: expected scanned=11 in the first run's summary — got: $(cat "$run1_out")"
fi

# =============================================================================
# Assertion group 7 — extract_subject is fully case-insensitive on the
# header token itself (regression for the ALL-CAPS "SUBJECT:" case: the old
# sed only matched "Subject:"/"subject:", so a nonstandard-cased header
# yielded an empty subject and the otp-security rule silently never fired).
# Isolated one-off store: the shared fixture above is pinned to exactly 11
# scanned / 5 held by several assertions, so this case gets its own tiny
# store rather than perturbing those counts.
# =============================================================================

capscase_store="$WORK_DIR/capscase-store"
mkdir -p "$capscase_store/inbox"
cat > "$capscase_store/inbox/hold-otp-caps-subject.md" <<'EOF_FIXTURE'
---
schema_version: 1.2.0
id: hold-otp-caps-subject
source: gmail-in
captured_at: 2026-08-03T09:00:00Z
type: email
participant-hints:
  - "security@bigbank.example.com"
---
SUBJECT: Your one-time passcode

Use code 482913 to sign in to your account.
EOF_FIXTURE

capscase_data="$WORK_DIR/capscase-data"
capscase_out="$WORK_DIR/capscase-out.txt"
"$TRIAGE" "$capscase_store" --data-dir "$capscase_data" > "$capscase_out" 2>/dev/null

capscase_held="$capscase_data/triage-held.log"
assert_ledger_line "$capscase_held" "hold-otp-caps-subject" "otp-security"

# =============================================================================
# Fix-round test (plan 27, T-F4) — sender_known's name-part check must
# consult people/*.md only, never index.json's raw structure. Dedicated
# store: packages/ingestion/tests/fixtures/triage/store-tf4/, synthetic
# PII only.
#
#   index.json      — a "mei-liu" entry (the slug/field token, literal JSON
#                      key text) that never appears verbatim in
#                      people/mei-liu.md's own text (that file spells the
#                      name "Mei Liu" with a space, never the hyphenated
#                      slug form).
#   people/mei-liu.md — name: Mei Liu.
#   inbox/cold-pitch-slug-name.md  — cold-pitch-shaped email, sender hint
#                      "mei-liu <spam@junkmail.example.net>" (display name
#                      equals the index.json-only slug token) — must still
#                      be held as cold-pitch (sender genuinely unknown; the
#                      old bug let the index.json substring match make it
#                      look known).
#   inbox/cold-pitch-known-name.md — same cold-pitch phrasing, sender hint
#                      "Mei Liu <friend@example.net>" (display name matches
#                      a real people/*.md name) — positive control, must
#                      NOT be held.
# =============================================================================

tf4_store="$REPO_ROOT/packages/ingestion/tests/fixtures/triage/store-tf4"

if [ ! -d "$tf4_store" ]; then
  fail "fix-round (T-F4) fixture missing at $tf4_store"
else
  tf4_data="$WORK_DIR/tf4-data"
  tf4_out="$WORK_DIR/tf4-out.txt"
  "$TRIAGE" "$tf4_store" --data-dir "$tf4_data" > "$tf4_out" 2>/dev/null
  tf4_status=$?

  if [ "$tf4_status" -eq 0 ]; then
    pass "T-F4: triage-inbox.sh exits 0 against the fix-round fixture store"
  else
    fail "T-F4: exited $tf4_status against the fix-round fixture store"
  fi

  tf4_held="$tf4_data/triage-held.log"
  assert_ledger_line "$tf4_held" "cold-pitch-slug-name" "cold-pitch"

  if grep -q '^cold-pitch-known-name	' "$tf4_held" 2>/dev/null; then
    fail "T-F4 (positive control): cold-pitch-known-name.md (display name matches a real people/*.md name) was incorrectly held"
  else
    pass "T-F4 (positive control): cold-pitch-known-name.md (display name matches a real people/*.md name) correctly not held"
  fi
fi

# =============================================================================
# Assertion group 8 — rule 6 (noise-sender): one held capture per seeded
# name in packages/ingestion/config/noise-senders.tsv's `from`/`ci-subject`
# rows, ledgered as `noise-sender:<name>`, plus a zero-false-hold check on
# a real-looking person email. Dedicated store:
# packages/ingestion/tests/fixtures/triage/store-noise/, synthetic PII
# only. (The two remaining shipped rows, verification-code-subject and
# security-alert-subject, are intentionally not exercised here — both are
# always shadowed by rule 3 (otp-security), which runs earlier and matches
# the identical subject phrasing first; see the noise-sender-shadow
# assertion below.)
# =============================================================================

noise_store="$REPO_ROOT/packages/ingestion/tests/fixtures/triage/store-noise"

if [ ! -d "$noise_store" ]; then
  fail "rule 6 fixture missing at $noise_store"
else
  noise_data="$WORK_DIR/noise-data"
  noise_out="$WORK_DIR/noise-out.txt"
  "$TRIAGE" "$noise_store" --data-dir "$noise_data" > "$noise_out" 2>/dev/null
  noise_status=$?

  if [ "$noise_status" -eq 0 ]; then
    pass "rule 6: triage-inbox.sh exits 0 against the store-noise fixture"
  else
    fail "rule 6: exited $noise_status against the store-noise fixture"
  fi

  noise_held="$noise_data/triage-held.log"

  for pair in \
    "hold-noise-github:noise-sender:github" \
    "hold-noise-vercel:noise-sender:vercel" \
    "hold-noise-slack:noise-sender:slack" \
    "hold-noise-google-notifications:noise-sender:google-notifications" \
    "hold-noise-ci-sender:noise-sender:ci-sender" \
    "hold-noise-security:noise-sender:security" \
    "hold-noise-newsletter:noise-sender:newsletter" \
    "hold-noise-transactional:noise-sender:transactional" \
    "hold-noise-ci-subject:noise-sender:ci-subject"
  do
    pid="${pair%%:*}"
    prule="${pair#*:}"
    assert_ledger_line "$noise_held" "$pid" "$prule"
  done

  noise_held_count="$(wc -l < "$noise_held" 2>/dev/null | tr -d ' ')"
  if [ "$noise_held_count" = "9" ]; then
    pass "rule 6: exactly 9 held lines (one per seeded name, no extras)"
  else
    fail "rule 6: expected exactly 9 held lines, got $noise_held_count"
  fi

  if grep -q '^golden-noise-real-person	' "$noise_held" 2>/dev/null; then
    fail "rule 6 zero-false-holds: golden-noise-real-person.md (real-looking alex@example.net sender) was incorrectly held"
  else
    pass "rule 6 zero-false-holds: golden-noise-real-person.md (real-looking alex@example.net sender) correctly not held"
  fi

  if grep -q 'per-rule=.*noise-sender:9,calendar-ignore:0$' "$noise_out"; then
    pass "rule 6: summary line's noise-sender count is 9"
  else
    fail "rule 6: summary line missing noise-sender:9 — got: $(cat "$noise_out")"
  fi
fi

# =============================================================================
# Assertion group 9 — noise-sender shadow note: the shipped
# verification-code-subject/security-alert-subject rows are present in the
# config (documenting rule 6's intended coverage) even though, for
# type: email, rule 3 (otp-security) always fires first on the identical
# subject phrasing — this pins that both rows still exist in the shipped
# table (a config-drift regression check), not that they are reachable.
# =============================================================================

noise_tsv="$REPO_ROOT/packages/ingestion/config/noise-senders.tsv"
if grep -q '^verification-code-subject	' "$noise_tsv" && grep -q '^security-alert-subject	' "$noise_tsv"; then
  pass "rule 6 config: verification-code-subject and security-alert-subject rows are present in the shipped table"
else
  fail "rule 6 config: verification-code-subject and/or security-alert-subject rows missing from $noise_tsv"
fi

# =============================================================================
# Assertion group 10 — local override table: <data-dir>/noise-senders.local.tsv.
# A local row sharing a shipped row's name overrides it (blocked below); a
# local-only new name is held under its own name. Both runs pre-seed
# --data-dir with the local tsv before invoking triage-inbox.sh, the same
# pattern the append-only group above uses for ledger pre-seeding.
# =============================================================================

override_block_data="$WORK_DIR/override-block-data"
mkdir -p "$override_block_data"
printf 'github\tNEVERMATCHXYZABC\tfrom\n' > "$override_block_data/noise-senders.local.tsv"
"$TRIAGE" "$noise_store" --data-dir "$override_block_data" >/dev/null 2>&1

override_block_held="$override_block_data/triage-held.log"
if grep -q '^hold-noise-github	' "$override_block_held" 2>/dev/null; then
  fail "local override (block): a local 'github' row with a non-matching regex should have blocked hold-noise-github.md, but it was still held"
else
  pass "local override (block): a local 'github' row with a non-matching regex correctly blocks hold-noise-github.md from being held"
fi

other_noise_held_count="$(wc -l < "$override_block_held" 2>/dev/null | tr -d ' ')"
if [ "$other_noise_held_count" = "8" ]; then
  pass "local override (block): the other 8 noise-sender names in store-noise are still held normally (override is scoped to 'github' only)"
else
  fail "local override (block): expected 8 other holds to survive, got $other_noise_held_count"
fi

override_newname_store="$REPO_ROOT/packages/ingestion/tests/fixtures/triage/store-noise-local-only"
if [ ! -d "$override_newname_store" ]; then
  fail "local override (new name) fixture missing at $override_newname_store"
else
  override_newname_data="$WORK_DIR/override-newname-data"
  mkdir -p "$override_newname_data"
  printf 'internal-bot\tbot@internal-tool\\.example\\.com\tfrom\n' > "$override_newname_data/noise-senders.local.tsv"
  "$TRIAGE" "$override_newname_store" --data-dir "$override_newname_data" >/dev/null 2>&1

  override_newname_held="$override_newname_data/triage-held.log"
  assert_ledger_line "$override_newname_held" "hold-noise-internal-bot" "noise-sender:internal-bot"
fi

# =============================================================================
# Assertion group 11 — rule 7 (calendar-ignore): declined-self and
# over-cap holds, a zero-false-hold small accepted meeting, a self-only
# block still ledgered as rule 2 (first-match-wins), a no-response-data
# event correctly not held (precision-first), and the calendar-max-
# attendees config override raising the cap so a 15-attendee event is no
# longer held. Dedicated store:
# packages/ingestion/tests/fixtures/triage/store-calignore/, synthetic
# PII only (example.net).
# =============================================================================

calignore_store="$REPO_ROOT/packages/ingestion/tests/fixtures/triage/store-calignore"

if [ ! -d "$calignore_store" ]; then
  fail "rule 7 fixture missing at $calignore_store"
else
  calignore_data="$WORK_DIR/calignore-data"
  calignore_out="$WORK_DIR/calignore-out.txt"
  "$TRIAGE" "$calignore_store" --data-dir "$calignore_data" > "$calignore_out" 2>/dev/null
  calignore_status=$?

  if [ "$calignore_status" -eq 0 ]; then
    pass "rule 7: triage-inbox.sh exits 0 against the store-calignore fixture"
  else
    fail "rule 7: exited $calignore_status against the store-calignore fixture"
  fi

  calignore_held="$calignore_data/triage-held.log"

  assert_ledger_line "$calignore_held" "hold-cal-declined" "calendar-ignore:skipped-declined"
  assert_ledger_line "$calignore_held" "hold-cal-large" "calendar-ignore:skipped-large:15"
  assert_ledger_line "$calignore_held" "hold-cal-self-only" "self-only-calendar"

  calignore_held_count="$(wc -l < "$calignore_held" 2>/dev/null | tr -d ' ')"
  if [ "$calignore_held_count" = "3" ]; then
    pass "rule 7: exactly 3 held lines (declined, over-cap, and the self-only block claimed by rule 2 — no extras)"
  else
    fail "rule 7: expected exactly 3 held lines, got $calignore_held_count"
  fi

  if grep -q '^golden-cal-accepted-small	' "$calignore_held" 2>/dev/null; then
    fail "rule 7 zero-false-holds: golden-cal-accepted-small.md (3-person accepted meeting) was incorrectly held"
  else
    pass "rule 7 zero-false-holds: golden-cal-accepted-small.md (3-person accepted meeting) correctly not held"
  fi

  if grep -q '^golden-cal-no-response-data	' "$calignore_held" 2>/dev/null; then
    fail "rule 7 precision-first: golden-cal-no-response-data.md (attendees present, no responseStatus fields) was incorrectly held"
  else
    pass "rule 7 precision-first: golden-cal-no-response-data.md (attendees present, no responseStatus fields) correctly not held"
  fi

  if grep -q 'per-rule=.*calendar-ignore:2$' "$calignore_out"; then
    pass "rule 7: summary line's calendar-ignore count is 2 (declined + over-cap; the self-only hold counts under self-only-calendar, not here)"
  else
    fail "rule 7: summary line missing calendar-ignore:2 — got: $(cat "$calignore_out")"
  fi
fi

# --- calendar-max-attendees config override: the 15-attendee event is no
# longer held once the local config raises the cap to 20. ------------------

if [ -d "$calignore_store" ]; then
  calignore_override_data="$WORK_DIR/calignore-override-data"
  mkdir -p "$WORK_DIR/config"
  printf 'calendar-max-attendees\t20\n' > "$WORK_DIR/config/onboarding-backfill.tsv"
  "$TRIAGE" "$calignore_store" --data-dir "$calignore_override_data" >/dev/null 2>&1

  calignore_override_held="$calignore_override_data/triage-held.log"
  if grep -q '^hold-cal-large	' "$calignore_override_held" 2>/dev/null; then
    fail "rule 7 config override: calendar-max-attendees=20 should have unheld the 15-attendee event, but it was still held"
  else
    pass "rule 7 config override: calendar-max-attendees=20 correctly unholds the 15-attendee event (15 <= 20)"
  fi

  if grep -q '^hold-cal-declined	' "$calignore_override_held" 2>/dev/null; then
    pass "rule 7 config override: the declined-self hold is unaffected by the attendee-cap override"
  else
    fail "rule 7 config override: hold-cal-declined should still be held (declined-self is independent of the attendee cap)"
  fi
fi

# =============================================================================
echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
