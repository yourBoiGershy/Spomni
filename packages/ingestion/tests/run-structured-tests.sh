#!/usr/bin/env bash
# packages/ingestion/tests/run-structured-tests.sh
#
# Regression-locks packages/ingestion/scripts/file-structured.sh (plan 31
# U1) against packages/ingestion/tests/fixtures/structured/, per plan 31
# unit 2. Same style as run-triage-tests.sh: numbered assertions via
# pass()/fail(), a SUMMARY line, non-zero exit on any failure. bash 3.2
# portable (no associative arrays, no mapfile).
#
# Contract under test (packages/ingestion/scripts/file-structured.sh):
#
#   file-structured.sh <store-dir> [--data-dir <dir>] [--today YYYY-MM-DD]
#                       [--dry-run] [--no-index] [--relearn]
#
# Eligible = type: calendar-event, or source gmail-in/* whose body is
# metadata-only (< 40 words after a leading "Subject:" line). Ids already
# in debrief-filed.log / triage-held.log / structured-held.log are skipped.
# Hints resolve email-exact -> slug, else unique normalized-name -> slug;
# self hints (per <data-dir>/config/onboarding-backfill.tsv "self<TAB>..."
# rows) are dropped first; zero non-self hints -> skipped; >=2 name matches
# -> whole event held "ambiguous-name:<name>"; unknown email with no name
# -> held "no-name:<email>"; unknown with a name -> new person file (name +
# last-touch only, no Facts bullets). Existing person: only last-touch may
# change (and only if newer) — a tier: line must be byte-identical after
# the run. One interaction per filed event, ## Summary prefixed
# 'Calendar: "' / 'Email: "', ## Commitments _none_. build-index.sh runs
# once at the end unless --no-index/--dry-run. Idempotent on a second run
# over the same inbox + ledgers.
#
# Fixtures (packages/ingestion/tests/fixtures/structured/), all synthetic
# PII (invented names, example.test emails — nothing from any real store):
#
#   config/onboarding-backfill.tsv — self rows (me@example.test, "Me
#     Myself"), copied into each case's --data-dir/config/.
#   cases/01-two-known/    — calendar event, two known people by email
#     (plus a self attendee that must be dropped as a hint, never treated
#     as a third/unknown person).
#   cases/02-new-person/   — calendar event, one known + one unknown
#     "Name <email>" hint -> new person file.
#   cases/03-gmail-metadata/ — gmail event, Subject + 5-word body -> filed.
#   cases/03-gmail-body/    — gmail event, Subject + 60-word body ->
#     ineligible, must never appear in any of the three ledgers.
#   cases/04-ambiguous/    — two distinct people/*.md both named "Sam Lee",
#     event hint is the bare name -> whole event held, no interaction.
#   cases/05-self-only/    — calendar event whose only hint is a self
#     identity -> skipped, nothing written.
#   cases/07-tier-preserve/ — existing person with tier: close and an
#     older last-touch; after filing, the tier: line is byte-identical and
#     last-touch has moved to the event's date.
#   cases/09-bare-email-body-name/ — calendar hint is a bare email with no
#     display name of its own; the body JSON's attendee entry supplies one
#     -> a new person is created under the borrowed name.
#   cases/10-identities-bootstrap/ — identities.tsv absent; an existing
#     interactions/*.md + its inbox/ event force a 1 slug <-> 1 email
#     pairing, exercising the bootstrap pass ("identities: learned=1") and
#     a second, brand-new bare-email event that resolves via the freshly
#     learned identity instead of holding as no-name.
#   cases/11a-single-token-local-part/ — unknown bare-email attendee whose
#     local-part is a single >=3-letter token ("patrick") -> filed, new
#     person people/patrick.md with tags: [name-from-email] (live-corpus
#     rebalance: plain first-name local-parts dominate real calendars and
#     the model path has no more info than the local-part either).
#   cases/11b-one-letter-token/ — unknown bare-email attendee whose
#     local-part has a 1-letter token inside a multi-token split
#     ("a.bhandhoal") -> still held no-name (the 1-letter-token floor
#     applies within a dot/underscore/hyphen split, unlike a bare single
#     token).
#   cases/11c-two-token-local-part/ — unknown bare-email attendee whose
#     local-part is 2 letters-only tokens each >=2 letters
#     ("thomas.wright") -> filed, new person with tags: [name-from-email].
#   cases/11d-too-short-single-token/ — unknown bare-email attendee whose
#     local-part is a single token under 3 letters ("jo") -> held no-name
#     (too short to be a plausible name, unlike "patrick"/"christian").
#   cases/12-stale-identity-map/ — identities.tsv pre-seeded with a row
#     naming a slug that has no people/<slug>.md (the person file was
#     deleted after the pairing was learned); a calendar hint carrying its
#     own display name for that same email resolves via the name instead
#     of the stale slug, mints a new person, and the stale row is skipped
#     (reported as "identities: stale=1") but left in the ledger.
#
# Cases 06 (idempotency) and 08 (--dry-run) reuse case 01's fixture files
# directly rather than needing dedicated ones. Case 10a (identities.tsv is
# written on a plain resolved-email run) rides on case 01's own run rather
# than a dedicated fixture; case 12's "clean path prints identities:
# stale=0" assertion rides on case 01's own run too.
#
# Note: this suite deliberately does not exercise config "ignore" rows —
# the coordinator flagged that as still under revision in
# file-structured.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FILE_STRUCTURED="$REPO_ROOT/packages/ingestion/scripts/file-structured.sh"
BUILD_INDEX="$REPO_ROOT/packages/core/scripts/build-index.sh"
FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/structured"

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

if [ ! -d "$FIXTURES" ]; then
  echo "FAIL: fixtures missing at $FIXTURES"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -f "$FILE_STRUCTURED" ]; then
  echo "SCRIPT NOT YET PRESENT: $FILE_STRUCTURED does not exist — tests unrun."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed (script not yet present)"
  exit 0
fi

if [ ! -x "$FILE_STRUCTURED" ]; then
  echo "FAIL: $FILE_STRUCTURED exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# setup_case <case-name> <store-out-dir> — copies people/ + inbox/ from
# fixtures/structured/cases/<case-name>/ into <store-out-dir>, builds
# index.json via build-index.sh, and returns 0. <store-out-dir> must not
# already exist.
setup_case() {
  case_name="$1"
  store_dir="$2"
  case_src="$FIXTURES/cases/$case_name"
  mkdir -p "$store_dir/people" "$store_dir/inbox" "$store_dir/interactions"
  if [ -d "$case_src/people" ]; then
    cp "$case_src/people/"*.md "$store_dir/people/" 2>/dev/null || true
  fi
  if [ -d "$case_src/interactions" ]; then
    cp "$case_src/interactions/"*.md "$store_dir/interactions/" 2>/dev/null || true
  fi
  cp "$case_src/inbox/"*.md "$store_dir/inbox/" 2>/dev/null || true
  "$BUILD_INDEX" "$store_dir" >/dev/null 2>&1 || true
}

# setup_data_dir <data-dir> — creates <data-dir>/config/onboarding-backfill.tsv
# from the shared fixture (self identities only).
setup_data_dir() {
  data_dir="$1"
  mkdir -p "$data_dir/config"
  cp "$FIXTURES/config/onboarding-backfill.tsv" "$data_dir/config/onboarding-backfill.tsv"
}

# =============================================================================
# Case 1 — calendar event, two known people by email.
# =============================================================================

c1_store="$WORK_DIR/c1-store"
c1_data="$WORK_DIR/c1-data"
setup_case "01-two-known" "$c1_store"
setup_data_dir "$c1_data"

c1_out="$WORK_DIR/c1-out.txt"
"$FILE_STRUCTURED" "$c1_store" --data-dir "$c1_data" > "$c1_out" 2>"$WORK_DIR/c1-err.txt"
c1_status=$?

if [ "$c1_status" -eq 0 ]; then
  pass "case 1: file-structured.sh exits 0"
else
  fail "case 1: exited $c1_status: $(cat "$WORK_DIR/c1-err.txt")"
fi

c1_interactions="$(ls "$c1_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$c1_interactions" = "1" ]; then
  pass "case 1: exactly one interaction file written"
else
  fail "case 1: expected exactly 1 interaction file, got $c1_interactions"
fi

c1_interaction_file="$(ls "$c1_store/interactions/"*.md 2>/dev/null | head -1)"
if [ -n "$c1_interaction_file" ] && grep -q '\[\[dana-brooks\]\]' "$c1_interaction_file" && grep -q '\[\[priya-shah\]\]' "$c1_interaction_file"; then
  pass "case 1: interaction people list includes both known slugs"
else
  fail "case 1: interaction people list missing one or both known slugs (file: $c1_interaction_file)"
fi

if [ -n "$c1_interaction_file" ] && grep -q '^calendar-event: evt-two-known-001$' "$c1_interaction_file"; then
  pass "case 1: calendar-event field set to the event JSON's .id"
else
  fail "case 1: calendar-event field not set to evt-two-known-001 (file: $c1_interaction_file)"
fi

if [ -n "$c1_interaction_file" ] && grep -q '^Calendar: "' "$c1_interaction_file"; then
  pass "case 1: ## Summary starts with 'Calendar: \"'"
else
  fail "case 1: ## Summary does not start with 'Calendar: \"' (file: $c1_interaction_file)"
fi

if grep -q '^cal-two-known$' "$c1_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "case 1: debrief-filed.log has a line for cal-two-known"
else
  fail "case 1: debrief-filed.log missing a line for cal-two-known"
fi

if grep -q 'filed=1 people_new=0' "$c1_out"; then
  pass "case 1: summary line reports filed=1 people_new=0"
else
  fail "case 1: summary line mismatch — got: $(cat "$c1_out")"
fi

if grep -q '^identities: stale=0$' "$c1_out"; then
  pass "case 12: clean path (case 1's own run, no identities.tsv yet) prints identities: stale=0"
else
  fail "case 12: expected 'identities: stale=0' on the clean path — got: $(cat "$c1_out")"
fi

# --- Case 10a (identities.tsv is written when an email resolves) ---
# Reuses case 1's already-completed run: both hints resolved by email, so
# identities.tsv should now hold a slug<TAB>email<TAB>capture-id row for
# each.
c1_identities="$c1_data/ingestion/identities.tsv"
if [ -f "$c1_identities" ] && grep -qF "$(printf 'dana-brooks\tdana.brooks@example.test\tcal-two-known')" "$c1_identities"; then
  pass "case 10a: identities.tsv records dana-brooks <-> dana.brooks@example.test <-> cal-two-known"
else
  fail "case 10a: identities.tsv missing/incorrect dana-brooks row — got: $(cat "$c1_identities" 2>/dev/null)"
fi

# =============================================================================
# Case 2 — calendar event, one unknown "Name <email>" hint -> new person.
# =============================================================================

c2_store="$WORK_DIR/c2-store"
c2_data="$WORK_DIR/c2-data"
setup_case "02-new-person" "$c2_store"
setup_data_dir "$c2_data"

c2_out="$WORK_DIR/c2-out.txt"
"$FILE_STRUCTURED" "$c2_store" --data-dir "$c2_data" > "$c2_out" 2>/dev/null
c2_status=$?

if [ "$c2_status" -eq 0 ]; then
  pass "case 2: file-structured.sh exits 0"
else
  fail "case 2: exited $c2_status"
fi

if [ -f "$c2_store/people/jamie-fox.md" ]; then
  pass "case 2: new person file people/jamie-fox.md created"
else
  fail "case 2: people/jamie-fox.md not created"
fi

if [ -f "$c2_store/people/jamie-fox.md" ]; then
  if grep -q '^name: Jamie Fox$' "$c2_store/people/jamie-fox.md" && grep -q '^last-touch: 2026-09-11$' "$c2_store/people/jamie-fox.md"; then
    pass "case 2: new person file has name + last-touch"
  else
    fail "case 2: new person file missing expected name/last-touch fields"
  fi

  if grep -q '^\s*-\s*\*\*\[' "$c2_store/people/jamie-fox.md"; then
    fail "case 2: new person file has provenance-tagged Facts bullets (D2 forbids invented provenance)"
  else
    pass "case 2: new person file has no Facts bullets"
  fi
fi

if grep -q 'people_new=1' "$c2_out"; then
  pass "case 2: summary line reports people_new=1"
else
  fail "case 2: summary line mismatch — got: $(cat "$c2_out")"
fi

# =============================================================================
# Case 3a — gmail metadata-only event (Subject + 5 words) -> filed.
# =============================================================================

c3a_store="$WORK_DIR/c3a-store"
c3a_data="$WORK_DIR/c3a-data"
setup_case "03-gmail-metadata" "$c3a_store"
setup_data_dir "$c3a_data"

c3a_out="$WORK_DIR/c3a-out.txt"
"$FILE_STRUCTURED" "$c3a_store" --data-dir "$c3a_data" > "$c3a_out" 2>/dev/null

c3a_interaction_file="$(ls "$c3a_store/interactions/"*.md 2>/dev/null | head -1)"
if [ -n "$c3a_interaction_file" ] && grep -q '^Email: "' "$c3a_interaction_file"; then
  pass "case 3a: gmail metadata-only event filed, ## Summary starts with 'Email: \"'"
else
  fail "case 3a: gmail metadata-only event not filed with an 'Email: \"' summary (file: $c3a_interaction_file)"
fi

if grep -q '^gmail-metadata$' "$c3a_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "case 3a: gmail-metadata id recorded in debrief-filed.log"
else
  fail "case 3a: gmail-metadata id missing from debrief-filed.log"
fi

# =============================================================================
# Case 3b — gmail event with a 60-word body -> ineligible, never in any ledger.
# =============================================================================

c3b_store="$WORK_DIR/c3b-store"
c3b_data="$WORK_DIR/c3b-data"
setup_case "03-gmail-body" "$c3b_store"
setup_data_dir "$c3b_data"

"$FILE_STRUCTURED" "$c3b_store" --data-dir "$c3b_data" > "$WORK_DIR/c3b-out.txt" 2>/dev/null

c3b_in_any_ledger=0
for log in "$c3b_data/ingestion/debrief-filed.log" "$c3b_data/ingestion/triage-held.log" "$c3b_data/ingestion/structured-held.log"; do
  if [ -f "$log" ] && grep -q '^gmail-body	' "$log" 2>/dev/null; then
    c3b_in_any_ledger=1
  fi
done
if [ "$c3b_in_any_ledger" -eq 0 ]; then
  pass "case 3b: 60-word gmail body event (ineligible) never appears in any ledger"
else
  fail "case 3b: 60-word gmail body event unexpectedly appears in a ledger"
fi

if [ ! -e "$c3b_store/interactions" ] || [ "$(ls "$c3b_store/interactions" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 3b: no interaction written for the 60-word gmail body event"
else
  fail "case 3b: an interaction was unexpectedly written for the 60-word gmail body event"
fi

# =============================================================================
# Case 4 — ambiguous bare-name hint matching two people -> held, no interaction.
# =============================================================================

c4_store="$WORK_DIR/c4-store"
c4_data="$WORK_DIR/c4-data"
setup_case "04-ambiguous" "$c4_store"
setup_data_dir "$c4_data"

"$FILE_STRUCTURED" "$c4_store" --data-dir "$c4_data" > "$WORK_DIR/c4-out.txt" 2>/dev/null

c4_held="$c4_data/ingestion/structured-held.log"
if [ -f "$c4_held" ] && grep -q '^cal-ambiguous	ambiguous-name:Sam Lee	' "$c4_held"; then
  pass "case 4: cal-ambiguous held with reason ambiguous-name:Sam Lee"
else
  fail "case 4: expected 'cal-ambiguous\tambiguous-name:Sam Lee\t<ts>' in structured-held.log — got: $(cat "$c4_held" 2>/dev/null)"
fi

if [ ! -e "$c4_store/interactions" ] || [ "$(ls "$c4_store/interactions" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 4: no interaction written for the ambiguous event"
else
  fail "case 4: an interaction was unexpectedly written for the ambiguous event"
fi

# =============================================================================
# Case 5 — self-only calendar event -> skipped, nothing written.
# =============================================================================

c5_store="$WORK_DIR/c5-store"
c5_data="$WORK_DIR/c5-data"
setup_case "05-self-only" "$c5_store"
setup_data_dir "$c5_data"

c5_out="$WORK_DIR/c5-out.txt"
"$FILE_STRUCTURED" "$c5_store" --data-dir "$c5_data" > "$c5_out" 2>/dev/null

if [ ! -e "$c5_store/interactions" ] || [ "$(ls "$c5_store/interactions" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 5: no interaction written for the self-only calendar event"
else
  fail "case 5: an interaction was unexpectedly written for the self-only calendar event"
fi

c5_in_any_ledger=0
for log in "$c5_data/ingestion/debrief-filed.log" "$c5_data/ingestion/triage-held.log" "$c5_data/ingestion/structured-held.log"; do
  if [ -f "$log" ] && grep -q '^cal-self-only	' "$log" 2>/dev/null; then
    c5_in_any_ledger=1
  fi
done
if [ "$c5_in_any_ledger" -eq 0 ]; then
  pass "case 5: self-only event never appears in any ledger (skipped, not held)"
else
  fail "case 5: self-only event unexpectedly appears in a ledger"
fi

if grep -q 'skipped=1' "$c5_out"; then
  pass "case 5: summary line reports skipped=1"
else
  fail "case 5: summary line mismatch — got: $(cat "$c5_out")"
fi

# =============================================================================
# Case 6 — idempotency: run twice, second summary filed=0, interaction count
# unchanged.
# =============================================================================

c6_store="$WORK_DIR/c6-store"
c6_data="$WORK_DIR/c6-data"
setup_case "01-two-known" "$c6_store"
setup_data_dir "$c6_data"

"$FILE_STRUCTURED" "$c6_store" --data-dir "$c6_data" > "$WORK_DIR/c6-run1.txt" 2>/dev/null
c6_count_after_run1="$(ls "$c6_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"

c6_run2_out="$WORK_DIR/c6-run2.txt"
"$FILE_STRUCTURED" "$c6_store" --data-dir "$c6_data" > "$c6_run2_out" 2>/dev/null
c6_run2_status=$?
c6_count_after_run2="$(ls "$c6_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"

if [ "$c6_run2_status" -eq 0 ] && grep -q 'filed=0 ' "$c6_run2_out"; then
  pass "case 6: idempotency — second run exits 0 and reports filed=0"
else
  fail "case 6: idempotency — second run exit=$c6_run2_status, summary: $(cat "$c6_run2_out")"
fi

if [ "$c6_count_after_run1" = "$c6_count_after_run2" ]; then
  pass "case 6: idempotency — interaction file count unchanged across the second run ($c6_count_after_run2)"
else
  fail "case 6: idempotency — interaction count changed ($c6_count_after_run1 -> $c6_count_after_run2)"
fi

# =============================================================================
# Case 7 — existing person: tier: line byte-identical, last-touch updated.
# =============================================================================

c7_store="$WORK_DIR/c7-store"
c7_data="$WORK_DIR/c7-data"
setup_case "07-tier-preserve" "$c7_store"
setup_data_dir "$c7_data"

"$FILE_STRUCTURED" "$c7_store" --data-dir "$c7_data" > "$WORK_DIR/c7-out.txt" 2>/dev/null

if grep -q '^tier: close$' "$c7_store/people/jordan-price.md"; then
  pass "case 7: tier: close line byte-identical after the run"
else
  fail "case 7: tier: line changed — $(grep '^tier:' "$c7_store/people/jordan-price.md" 2>/dev/null)"
fi

if grep -q '^last-touch: 2026-09-14$' "$c7_store/people/jordan-price.md"; then
  pass "case 7: last-touch updated to the event's date (2026-09-14)"
else
  fail "case 7: last-touch not updated to 2026-09-14 — $(grep '^last-touch:' "$c7_store/people/jordan-price.md" 2>/dev/null)"
fi

# =============================================================================
# Case 8 — --dry-run writes nothing but prints the summary line.
# =============================================================================

c8_store="$WORK_DIR/c8-store"
c8_data="$WORK_DIR/c8-data"
setup_case "01-two-known" "$c8_store"

c8_out="$WORK_DIR/c8-out.txt"
"$FILE_STRUCTURED" "$c8_store" --data-dir "$c8_data" --dry-run > "$c8_out" 2>"$WORK_DIR/c8-err.txt"
c8_status=$?

if [ "$c8_status" -eq 0 ]; then
  pass "case 8: --dry-run exits 0"
else
  fail "case 8: --dry-run exited $c8_status: $(cat "$WORK_DIR/c8-err.txt")"
fi

if [ ! -e "$c8_store/interactions" ] || [ "$(ls "$c8_store/interactions" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 8: --dry-run writes no interaction files"
else
  fail "case 8: --dry-run unexpectedly wrote interaction file(s)"
fi

if [ ! -e "$c8_data" ]; then
  pass "case 8: --dry-run never creates --data-dir (no ledger writes)"
else
  fail "case 8: --dry-run unexpectedly created --data-dir: $(find "$c8_data" -type f 2>/dev/null)"
fi

if grep -q '^file-structured: eligible=' "$c8_out"; then
  pass "case 8: --dry-run still prints the summary line"
else
  fail "case 8: --dry-run did not print the expected summary line — got: $(cat "$c8_out")"
fi

# =============================================================================
# Case 9 — bare-email calendar hint (no display name of its own) borrows a
# display name from the calendar body's attendee JSON -> a new person is
# created under that borrowed name.
# =============================================================================

c9_store="$WORK_DIR/c9-store"
c9_data="$WORK_DIR/c9-data"
setup_case "09-bare-email-body-name" "$c9_store"
setup_data_dir "$c9_data"

c9_out="$WORK_DIR/c9-out.txt"
"$FILE_STRUCTURED" "$c9_store" --data-dir "$c9_data" > "$c9_out" 2>"$WORK_DIR/c9-err.txt"
c9_status=$?

if [ "$c9_status" -eq 0 ]; then
  pass "case 9: file-structured.sh exits 0"
else
  fail "case 9: exited $c9_status: $(cat "$WORK_DIR/c9-err.txt")"
fi

if [ -f "$c9_store/people/morgan-lee.md" ] && grep -q '^name: Morgan Lee$' "$c9_store/people/morgan-lee.md"; then
  pass "case 9: bare-email hint borrowed the body's displayName and created people/morgan-lee.md (name: Morgan Lee)"
else
  fail "case 9: people/morgan-lee.md missing or wrong name — $(cat "$c9_store/people/morgan-lee.md" 2>/dev/null)"
fi

if grep -q 'people_new=1' "$c9_out"; then
  pass "case 9: summary line reports people_new=1"
else
  fail "case 9: summary line mismatch — got: $(cat "$c9_out")"
fi

# =============================================================================
# Case 10b — identities.tsv absent; an existing interaction + its inbox
# event force a 1 slug <-> 1 email pairing (bootstrap). Expect
# "identities: learned=1" on stdout, identities.tsv written, and the next
# bare-email event for that address resolves to the same slug instead of
# holding as no-name.
# =============================================================================

c10_store="$WORK_DIR/c10-store"
c10_data="$WORK_DIR/c10-data"
setup_case "10-identities-bootstrap" "$c10_store"
setup_data_dir "$c10_data"
mkdir -p "$c10_data/ingestion"
printf 'gmail-old-taylor\n' > "$c10_data/ingestion/debrief-filed.log"

c10_out="$WORK_DIR/c10-out.txt"
"$FILE_STRUCTURED" "$c10_store" --data-dir "$c10_data" > "$c10_out" 2>"$WORK_DIR/c10-err.txt"
c10_status=$?

if [ "$c10_status" -eq 0 ]; then
  pass "case 10b: file-structured.sh exits 0"
else
  fail "case 10b: exited $c10_status: $(cat "$WORK_DIR/c10-err.txt")"
fi

if grep -q '^identities: learned=1$' "$c10_out"; then
  pass "case 10b: stdout reports 'identities: learned=1' from the bootstrap pass"
else
  fail "case 10b: expected 'identities: learned=1' on stdout — got: $(cat "$c10_out")"
fi

c10_identities="$c10_data/ingestion/identities.tsv"
if [ -f "$c10_identities" ] && grep -qF "$(printf 'taylor-reed\ttaylor.reed@example.test\tgmail-old-taylor')" "$c10_identities"; then
  pass "case 10b: identities.tsv bootstrap-learned taylor-reed <-> taylor.reed@example.test <-> gmail-old-taylor"
else
  fail "case 10b: identities.tsv missing/incorrect bootstrapped row — got: $(cat "$c10_identities" 2>/dev/null)"
fi

if grep -q '^gmail-new-taylor$' "$c10_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "case 10b: the next bare-email event (gmail-new-taylor) resolved and filed via the learned identity, not held"
else
  fail "case 10b: gmail-new-taylor was not filed — debrief-filed.log: $(cat "$c10_data/ingestion/debrief-filed.log" 2>/dev/null); structured-held.log: $(cat "$c10_data/ingestion/structured-held.log" 2>/dev/null)"
fi

c10_new_interaction="$(ls "$c10_store/interactions/"*.md 2>/dev/null | grep -v '2026-08-20-taylor-reed.md' | head -1)"
if [ -n "$c10_new_interaction" ] && grep -q '\[\[taylor-reed\]\]' "$c10_new_interaction"; then
  pass "case 10b: the new interaction from gmail-new-taylor links [[taylor-reed]]"
else
  fail "case 10b: no new interaction resolving to [[taylor-reed]] found (file: $c10_new_interaction)"
fi

# =============================================================================
# Case 11a — bare-email attendee, single-token local-part >=3 letters
# ("patrick") -> filed, new person tagged name-from-email (live-corpus
# rebalance: holding plain first-name local-parts bought nothing and cost
# whole events, since the model path has no more information than the
# local-part either).
# =============================================================================

c11a_store="$WORK_DIR/c11a-store"
c11a_data="$WORK_DIR/c11a-data"
setup_case "11a-single-token-local-part" "$c11a_store"
setup_data_dir "$c11a_data"

c11a_out="$WORK_DIR/c11a-out.txt"
"$FILE_STRUCTURED" "$c11a_store" --data-dir "$c11a_data" > "$c11a_out" 2>"$WORK_DIR/c11a-err.txt"
c11a_status=$?

if [ "$c11a_status" -eq 0 ]; then
  pass "case 11a: file-structured.sh exits 0"
else
  fail "case 11a: exited $c11a_status: $(cat "$WORK_DIR/c11a-err.txt")"
fi

if [ -f "$c11a_store/people/patrick.md" ]; then
  if grep -q '^name: Patrick$' "$c11a_store/people/patrick.md" && grep -q '^tags: \[name-from-email\]$' "$c11a_store/people/patrick.md"; then
    pass "case 11a: people/patrick.md created with name: Patrick and tags: [name-from-email]"
  else
    fail "case 11a: people/patrick.md missing expected name/tags — $(cat "$c11a_store/people/patrick.md")"
  fi
else
  fail "case 11a: people/patrick.md not created"
fi

if grep -q 'people_new=1' "$c11a_out" && grep -q 'held=0' "$c11a_out"; then
  pass "case 11a: summary line reports people_new=1 held=0"
else
  fail "case 11a: summary line mismatch — got: $(cat "$c11a_out")"
fi

# =============================================================================
# Case 11b — bare-email attendee, 1-letter token in local-part
# ("a.bhandhoal") -> held no-name the same way.
# =============================================================================

c11b_store="$WORK_DIR/c11b-store"
c11b_data="$WORK_DIR/c11b-data"
setup_case "11b-one-letter-token" "$c11b_store"
setup_data_dir "$c11b_data"

c11b_out="$WORK_DIR/c11b-out.txt"
"$FILE_STRUCTURED" "$c11b_store" --data-dir "$c11b_data" > "$c11b_out" 2>"$WORK_DIR/c11b-err.txt"
c11b_status=$?

if [ "$c11b_status" -eq 0 ]; then
  pass "case 11b: file-structured.sh exits 0"
else
  fail "case 11b: exited $c11b_status: $(cat "$WORK_DIR/c11b-err.txt")"
fi

c11b_held="$c11b_data/ingestion/structured-held.log"
if [ -f "$c11b_held" ] && grep -q '^cal-bhandhoal	no-name:a.bhandhoal@example.test	' "$c11b_held"; then
  pass "case 11b: cal-bhandhoal held with reason no-name:a.bhandhoal@example.test"
else
  fail "case 11b: expected 'cal-bhandhoal\tno-name:a.bhandhoal@example.test\t<ts>' in structured-held.log — got: $(cat "$c11b_held" 2>/dev/null)"
fi

if [ ! -e "$c11b_store/people" ] || [ "$(ls "$c11b_store/people" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 11b: no person file created"
else
  fail "case 11b: an unexpected person file was created — $(ls "$c11b_store/people" 2>/dev/null)"
fi

if grep -q 'held=1 skipped=0' "$c11b_out" && grep -q 'filed=0 ' "$c11b_out"; then
  pass "case 11b: summary line reports held=1 filed=0"
else
  fail "case 11b: summary line mismatch — got: $(cat "$c11b_out")"
fi

# =============================================================================
# Case 11c — bare-email attendee, 2-token letters-only local-part
# ("thomas.wright") -> filed, new person with tags: [name-from-email].
# =============================================================================

c11c_store="$WORK_DIR/c11c-store"
c11c_data="$WORK_DIR/c11c-data"
setup_case "11c-two-token-local-part" "$c11c_store"
setup_data_dir "$c11c_data"

c11c_out="$WORK_DIR/c11c-out.txt"
"$FILE_STRUCTURED" "$c11c_store" --data-dir "$c11c_data" > "$c11c_out" 2>"$WORK_DIR/c11c-err.txt"
c11c_status=$?

if [ "$c11c_status" -eq 0 ]; then
  pass "case 11c: file-structured.sh exits 0"
else
  fail "case 11c: exited $c11c_status: $(cat "$WORK_DIR/c11c-err.txt")"
fi

if [ -f "$c11c_store/people/thomas-wright.md" ]; then
  if grep -q '^name: Thomas Wright$' "$c11c_store/people/thomas-wright.md" && grep -q '^tags: \[name-from-email\]$' "$c11c_store/people/thomas-wright.md"; then
    pass "case 11c: people/thomas-wright.md created with name: Thomas Wright and tags: [name-from-email]"
  else
    fail "case 11c: people/thomas-wright.md missing expected name/tags — $(cat "$c11c_store/people/thomas-wright.md")"
  fi
else
  fail "case 11c: people/thomas-wright.md not created"
fi

if grep -q 'people_new=1' "$c11c_out" && grep -q 'held=0' "$c11c_out"; then
  pass "case 11c: summary line reports people_new=1 held=0"
else
  fail "case 11c: summary line mismatch — got: $(cat "$c11c_out")"
fi

# =============================================================================
# Case 11d — bare-email attendee, single-token local-part under 3 letters
# ("jo") -> still held no-name (too short to be a plausible name).
# =============================================================================

c11d_store="$WORK_DIR/c11d-store"
c11d_data="$WORK_DIR/c11d-data"
setup_case "11d-too-short-single-token" "$c11d_store"
setup_data_dir "$c11d_data"

c11d_out="$WORK_DIR/c11d-out.txt"
"$FILE_STRUCTURED" "$c11d_store" --data-dir "$c11d_data" > "$c11d_out" 2>"$WORK_DIR/c11d-err.txt"
c11d_status=$?

if [ "$c11d_status" -eq 0 ]; then
  pass "case 11d: file-structured.sh exits 0"
else
  fail "case 11d: exited $c11d_status: $(cat "$WORK_DIR/c11d-err.txt")"
fi

c11d_held="$c11d_data/ingestion/structured-held.log"
if [ -f "$c11d_held" ] && grep -q '^cal-jo	no-name:jo@example.test	' "$c11d_held"; then
  pass "case 11d: cal-jo held with reason no-name:jo@example.test"
else
  fail "case 11d: expected 'cal-jo\tno-name:jo@example.test\t<ts>' in structured-held.log — got: $(cat "$c11d_held" 2>/dev/null)"
fi

if [ ! -e "$c11d_store/people" ] || [ "$(ls "$c11d_store/people" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  pass "case 11d: no person file created"
else
  fail "case 11d: an unexpected person file was created — $(ls "$c11d_store/people" 2>/dev/null)"
fi

if grep -q 'held=1 skipped=0' "$c11d_out" && grep -q 'filed=0 ' "$c11d_out"; then
  pass "case 11d: summary line reports held=1 filed=0"
else
  fail "case 11d: summary line mismatch — got: $(cat "$c11d_out")"
fi

# =============================================================================
# Case 12 — stale identity-map row: identities.tsv names a slug with no
# people/<slug>.md; the event's own display name resolves + mints a new
# person instead, the stale row is skipped (reported, not deleted).
# =============================================================================

c12_store="$WORK_DIR/c12-store"
c12_data="$WORK_DIR/c12-data"
setup_case "12-stale-identity-map" "$c12_store"
setup_data_dir "$c12_data"
mkdir -p "$c12_data/ingestion"
printf 'ghost	ghost@example.test	cap-1
' > "$c12_data/ingestion/identities.tsv"

c12_out="$WORK_DIR/c12-out.txt"
"$FILE_STRUCTURED" "$c12_store" --data-dir "$c12_data" > "$c12_out" 2>"$WORK_DIR/c12-err.txt"
c12_status=$?

if [ "$c12_status" -eq 0 ]; then
  pass "case 12: file-structured.sh exits 0"
else
  fail "case 12: exited $c12_status: $(cat "$WORK_DIR/c12-err.txt")"
fi

if grep -q '^identities: stale=1$' "$c12_out"; then
  pass "case 12: stdout reports 'identities: stale=1' for the dangling ghost row"
else
  fail "case 12: expected 'identities: stale=1' on stdout — got: $(cat "$c12_out")"
fi

if [ -f "$c12_store/people/ghost-person.md" ] && grep -q '^name: Ghost Person$' "$c12_store/people/ghost-person.md"; then
  pass "case 12: a new person people/ghost-person.md was minted from the hint's display name"
else
  fail "case 12: people/ghost-person.md missing or wrong name — $(cat "$c12_store/people/ghost-person.md" 2>/dev/null)"
fi

c12_interaction_file="$(ls "$c12_store/interactions/"*.md 2>/dev/null | head -1)"
if [ -n "$c12_interaction_file" ] && grep -q '\[\[ghost-person\]\]' "$c12_interaction_file" && ! grep -q '\[\[ghost\]\]' "$c12_interaction_file"; then
  pass "case 12: interaction links [[ghost-person]], not the stale [[ghost]] slug"
else
  fail "case 12: interaction does not link [[ghost-person]] correctly (file: $c12_interaction_file)"
fi

c12_identities="$c12_data/ingestion/identities.tsv"
if [ -f "$c12_identities" ] && grep -qF "$(printf 'ghost	ghost@example.test	cap-1')" "$c12_identities"; then
  pass "case 12: identities.tsv still contains the original stale ghost row (append-only, unpruned)"
else
  fail "case 12: original ghost row missing from identities.tsv — got: $(cat "$c12_identities" 2>/dev/null)"
fi

mkdir -p "$c12_store/wakeups"
c12_validate_out="$(bash "$REPO_ROOT/packages/core/scripts/validate-store.sh" "$c12_store" 2>&1)"
if printf '%s\n' "$c12_validate_out" | grep -q 'store clean'; then
  pass "case 12: validate-store.sh reports the resulting store clean"
else
  fail "case 12: validate-store.sh did not report clean — got: $c12_validate_out"
fi

# =============================================================================
# Reindex freshness (plan 38 D2) — wired in as a sub-suite; its own
# PASS/FAIL lines print inline, its SUMMARY counts fold into this
# runner's totals below rather than being reported twice.
# =============================================================================

REINDEX_TEST="$SCRIPT_DIR/test-reindex-freshness.sh"
if [ -x "$REINDEX_TEST" ]; then
  reindex_out="$("$REINDEX_TEST")"
  echo "$reindex_out"
  reindex_summary_line="$(printf '%s\n' "$reindex_out" | grep '^SUMMARY:')"
  reindex_pass="$(printf '%s\n' "$reindex_summary_line" | sed -E 's/^SUMMARY: ([0-9]+) passed.*/\1/')"
  reindex_fail="$(printf '%s\n' "$reindex_summary_line" | sed -E 's/^SUMMARY: [0-9]+ passed, ([0-9]+) failed.*/\1/')"
  case "$reindex_pass" in ''|*[!0-9]*) reindex_pass=0 ;; esac
  case "$reindex_fail" in ''|*[!0-9]*) reindex_fail=0 ;; esac
  PASS_COUNT=$((PASS_COUNT + reindex_pass))
  FAIL_COUNT=$((FAIL_COUNT + reindex_fail))
else
  fail "reindex freshness: $REINDEX_TEST missing or not executable"
fi

# =============================================================================
echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
