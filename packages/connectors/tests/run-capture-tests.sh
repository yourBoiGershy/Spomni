#!/usr/bin/env bash
# packages/connectors/tests/run-capture-tests.sh
#
# Asserts that packages/connectors/scripts/normalize-capture.sh, the shared
# capture normalizer, behaves correctly against the gmail-in and calendar-in
# fixture packs (packages/connectors/gmail-in/fixtures/,
# packages/connectors/calendar-in/fixtures/), per
# packages/core/contracts/capture-event.md:
#
#   1. valid fixtures normalize into inbox/<id>.md, exit 0, with correct
#      source/type/id frontmatter.
#   2. the body is written byte-for-byte verbatim.
#   3. --hint values land in participant-hints.
#   4. --type bogus quarantines (with a .reason.txt mentioning the invalid
#      type), exit 1, and never touches inbox/.
#   5. a duplicate --id quarantines the second attempt and leaves the first
#      inbox file unmodified.
#   6. an empty body is valid (capture is lossy-tolerant), exit 0.
#   7. malformed-junk.txt as a body with a VALID envelope is still written —
#      envelope validity gates, not body content.
#   8. quarantine never deletes: quarantined content equals the input.
#
# Also exercises the two lane-local helpers directly:
#   9. gmail-in/scripts/classify.sh typing rules ([ra] subject -> voice-note;
#      linkedin.com/*.linkedin.com From -> linkedin-notification; default ->
#      email; precedence when both fire).
#  10. calendar-in/scripts/extract-hints.sh against calendar-event.json
#      (organizer + creator + every attendee present, no self-filtering,
#      "Name <email>" / bare-email output forms).
#
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere. Uses a throwaway mktemp -d store,
# cleaned up on exit via trap.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

NORMALIZER="$REPO_ROOT/packages/connectors/scripts/normalize-capture.sh"
GMAIL_FIXTURES_DIR="$REPO_ROOT/packages/connectors/gmail-in/fixtures"
CALENDAR_FIXTURES_DIR="$REPO_ROOT/packages/connectors/calendar-in/fixtures"
CLASSIFY="$REPO_ROOT/packages/connectors/gmail-in/scripts/classify.sh"
EXTRACT_HINTS="$REPO_ROOT/packages/connectors/calendar-in/scripts/extract-hints.sh"
EXTRACT_BODY_SCRIPT="$REPO_ROOT/packages/connectors/gmail-in/scripts/extract-email-body.sh"

# Source values for the generic (lane-agnostic) tests below — any valid
# <connector>/<lane> string works; gmail-in/gmail is used throughout for
# consistency.
GENERIC_SOURCE="gmail-in/gmail"

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

# --- throwaway store, cleaned up on exit ---
STORE_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STORE_DIR"
}
trap cleanup EXIT

# --- normalizer + fixtures + helpers must exist ---
if [ ! -f "$NORMALIZER" ]; then
  echo "SKIP: $NORMALIZER not found — cannot run capture tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, normalizer missing"
  exit 1
fi

if [ ! -x "$NORMALIZER" ]; then
  echo "FAIL: $NORMALIZER exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$GMAIL_FIXTURES_DIR" ]; then
  echo "FAIL: gmail-in fixtures dir missing at $GMAIL_FIXTURES_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$CALENDAR_FIXTURES_DIR" ]; then
  echo "FAIL: calendar-in fixtures dir missing at $CALENDAR_FIXTURES_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$CLASSIFY" ]; then
  echo "FAIL: $CLASSIFY missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$EXTRACT_HINTS" ]; then
  echo "FAIL: $EXTRACT_HINTS missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$EXTRACT_BODY_SCRIPT" ]; then
  echo "FAIL: $EXTRACT_BODY_SCRIPT missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# --- helpers ---

# extract_body <file> — print everything after the second frontmatter
# delimiter line (a line that is exactly "---"), byte-for-byte, to stdout.
extract_body() {
  f="$1"
  line_number="$(grep -n '^---$' "$f" | sed -n '2p' | cut -d: -f1)"
  if [ -z "$line_number" ]; then
    return 1
  fi
  body_start=$((line_number + 1))
  tail -n +"$body_start" "$f"
}

# --- assertion 1 & 2: each valid fixture normalizes correctly, body verbatim
# --- run once per lane pack, against that lane's own --source value.
run_fixture_pack() {
  fixtures_dir="$1"
  fixture_source="$2"
  specs="$3"

  while IFS=':' read -r fname ftype; do
    [ -z "$fname" ] && continue

    fixture_path="$fixtures_dir/$fname"
    stem="${fname%.*}"

    if [ ! -f "$fixture_path" ]; then
      fail "fixture missing: $fixture_path"
      continue
    fi

    out="$("$NORMALIZER" "$STORE_DIR" --source "$fixture_source" --type "$ftype" --id "$stem" --file "$fixture_path" 2>&1)"
    status=$?
    dest="$STORE_DIR/inbox/$stem.md"

    if [ "$status" -eq 0 ]; then
      pass "$fname: normalize-capture.sh exits 0"
    else
      fail "$fname: normalize-capture.sh exited $status (expected 0): $out"
    fi

    if [ -f "$dest" ]; then
      pass "$fname: inbox file exists at $dest"
    else
      fail "$fname: inbox file missing at $dest"
    fi

    if [ -f "$dest" ]; then
      if grep -qF "id: $stem" "$dest"; then
        pass "$fname: frontmatter id matches filename stem ($stem)"
      else
        fail "$fname: frontmatter id does not match filename stem ($stem)"
      fi

      if grep -qF "source: $fixture_source" "$dest"; then
        pass "$fname: frontmatter source is $fixture_source"
      else
        fail "$fname: frontmatter source is not $fixture_source"
      fi

      if grep -qF "type: $ftype" "$dest"; then
        pass "$fname: frontmatter type is $ftype"
      else
        fail "$fname: frontmatter type is not $ftype"
      fi

      extracted="$(mktemp)"
      if extract_body "$dest" > "$extracted"; then
        if diff -q "$fixture_path" "$extracted" >/dev/null 2>&1; then
          pass "$fname: body is byte-for-byte verbatim"
        else
          fail "$fname: body does not match input verbatim"
        fi
      else
        fail "$fname: could not locate frontmatter delimiter to extract body"
      fi
      rm -f "$extracted"
    fi
  done <<< "$specs"
}

# gmail-in: default `email`, `[ra]`-subject -> voice-note,
# linkedin.com From -> linkedin-notification (per the plan-17 mapping table).
gmail_fixture_specs="
email.json:email
email-voice-note.json:voice-note
email-linkedin-notification.json:linkedin-notification
"
run_fixture_pack "$GMAIL_FIXTURES_DIR" "gmail-in/gmail" "$gmail_fixture_specs"

# calendar-in: every event (timed or all-day) types as calendar-event.
calendar_fixture_specs="
calendar-event.json:calendar-event
calendar-event-allday.json:calendar-event
"
run_fixture_pack "$CALENDAR_FIXTURES_DIR" "calendar-in/calendar" "$calendar_fixture_specs"

# --- enum coverage: no fixture above exercises these types directly (the
# sweeps only ever emit voice-note/email/linkedin-notification/calendar-event
# today; event-confirmation and transcript are reserved for a later filing
# chunk) — assert the normalizer still accepts each of them with a trivial
# body ---
remaining_enum_types="
linkedin-notification
event-confirmation
transcript
"

while IFS= read -r etype; do
  [ -z "$etype" ] && continue

  eid="enum-coverage-$etype"
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type "$etype" --id "$eid" 2>&1)"
  status=$?
  edest="$STORE_DIR/inbox/$eid.md"

  if [ "$status" -eq 0 ]; then
    pass "enum coverage: type $etype accepted, exit 0"
  else
    fail "enum coverage: type $etype rejected, exited $status (expected 0): $out"
  fi

  if [ -f "$edest" ]; then
    pass "enum coverage: type $etype inbox file written"
  else
    fail "enum coverage: type $etype inbox file missing at $edest"
  fi
done <<< "$remaining_enum_types"

# --- 1.1.0 enum coverage: email, calendar-event, profile-snapshot, post ---
new_enum_types="
email
calendar-event
profile-snapshot
post
"

while IFS= read -r netype; do
  [ -z "$netype" ] && continue

  neid="enum-coverage-1-1-0-$netype"
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type "$netype" --id "$neid" 2>&1)"
  status=$?
  nedest="$STORE_DIR/inbox/$neid.md"

  if [ "$status" -eq 0 ]; then
    pass "1.1.0 enum coverage: type $netype accepted, exit 0"
  else
    fail "1.1.0 enum coverage: type $netype rejected, exited $status (expected 0): $out"
  fi

  if [ -f "$nedest" ]; then
    pass "1.1.0 enum coverage: type $netype inbox file written"
    if grep -qF "type: $netype" "$nedest"; then
      pass "1.1.0 enum coverage: type $netype frontmatter matches"
    else
      fail "1.1.0 enum coverage: type $netype frontmatter does not match"
    fi
  else
    fail "1.1.0 enum coverage: type $netype inbox file missing at $nedest"
  fi
done <<< "$new_enum_types"

# --- 1.2.0 enum coverage: chat-message ---
newer_enum_types="
chat-message
"

while IFS= read -r cetype; do
  [ -z "$cetype" ] && continue

  ceid="enum-coverage-1-2-0-$cetype"
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type "$cetype" --id "$ceid" 2>&1)"
  status=$?
  cedest="$STORE_DIR/inbox/$ceid.md"

  if [ "$status" -eq 0 ]; then
    pass "1.2.0 enum coverage: type $cetype accepted, exit 0"
  else
    fail "1.2.0 enum coverage: type $cetype rejected, exited $status (expected 0): $out"
  fi

  if [ -f "$cedest" ]; then
    pass "1.2.0 enum coverage: type $cetype inbox file written"
    if grep -qF "type: $cetype" "$cedest"; then
      pass "1.2.0 enum coverage: type $cetype frontmatter matches"
    else
      fail "1.2.0 enum coverage: type $cetype frontmatter does not match"
    fi
  else
    fail "1.2.0 enum coverage: type $cetype inbox file missing at $cedest"
  fi
done <<< "$newer_enum_types"

# --- schema_version: emitted value is 1.2.0 ---
schema_check_dest="$STORE_DIR/inbox/enum-coverage-1-1-0-email.md"
if [ -f "$schema_check_dest" ]; then
  if grep -qF "schema_version: 1.2.0" "$schema_check_dest"; then
    pass "schema_version: emitted value is 1.2.0"
  else
    fail "schema_version: emitted value is not 1.2.0 in $schema_check_dest"
  fi
else
  fail "schema_version check: $schema_check_dest missing"
fi

# --- occurred_at: valid --occurred-at is emitted after captured_at ---
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type email --id occurred-at-valid --occurred-at 2026-08-29T12:00:00Z 2>&1)"
status=$?
occurred_dest="$STORE_DIR/inbox/occurred-at-valid.md"

if [ "$status" -eq 0 ] && [ -f "$occurred_dest" ]; then
  pass "occurred_at: valid --occurred-at accepted, exit 0"
  captured_line="$(grep -n '^captured_at:' "$occurred_dest" | head -n1 | cut -d: -f1)"
  occurred_line="$(grep -n '^occurred_at:' "$occurred_dest" | head -n1 | cut -d: -f1)"
  if grep -qF "occurred_at: 2026-08-29T12:00:00Z" "$occurred_dest"; then
    pass "occurred_at: value matches the passed --occurred-at"
  else
    fail "occurred_at: value does not match the passed --occurred-at in $occurred_dest"
  fi
  if [ -n "$captured_line" ] && [ -n "$occurred_line" ] && [ "$occurred_line" -eq $((captured_line + 1)) ]; then
    pass "occurred_at: line placed immediately after captured_at"
  else
    fail "occurred_at: line not placed immediately after captured_at (captured_at at $captured_line, occurred_at at $occurred_line)"
  fi
else
  fail "occurred_at: valid --occurred-at did not succeed (status $status): $out"
fi

# --- occurred_at: omitting the flag produces no occurred_at line ---
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type email --id occurred-at-absent 2>&1)"
status=$?
absent_dest="$STORE_DIR/inbox/occurred-at-absent.md"

if [ "$status" -eq 0 ] && [ -f "$absent_dest" ]; then
  if grep -q '^occurred_at:' "$absent_dest"; then
    fail "occurred_at: line present despite --occurred-at being omitted in $absent_dest"
  else
    pass "occurred_at: no line emitted when --occurred-at is omitted"
  fi
else
  fail "occurred_at absent test: normalize-capture.sh did not succeed (status $status): $out"
fi

# --- occurred_at: malformed --occurred-at quarantines with reason mentioning occurred_at ---
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type email --id occurred-at-malformed --occurred-at not-a-date 2>&1)"
status=$?
malformed_inbox="$STORE_DIR/inbox/occurred-at-malformed.md"
malformed_quarantine="$STORE_DIR/inbox/quarantine/occurred-at-malformed.md"
malformed_reason="$STORE_DIR/inbox/quarantine/occurred-at-malformed.reason.txt"

if [ "$status" -eq 1 ]; then
  pass "occurred_at malformed (not-a-date): normalize-capture.sh exits 1"
else
  fail "occurred_at malformed (not-a-date): normalize-capture.sh exited $status (expected 1)"
fi

if [ ! -e "$malformed_inbox" ]; then
  pass "occurred_at malformed (not-a-date): no inbox file written"
else
  fail "occurred_at malformed (not-a-date): an inbox file was written despite malformed occurred_at"
fi

if [ -f "$malformed_quarantine" ]; then
  pass "occurred_at malformed (not-a-date): quarantine file exists"
else
  fail "occurred_at malformed (not-a-date): quarantine file missing at $malformed_quarantine"
fi

if [ -f "$malformed_reason" ] && grep -qi "occurred_at" "$malformed_reason"; then
  pass "occurred_at malformed (not-a-date): .reason.txt mentions occurred_at"
else
  fail "occurred_at malformed (not-a-date): .reason.txt missing or does not mention occurred_at"
fi

# --- occurred_at: near-miss malformed --occurred-at (space instead of T) quarantines too ---
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type email --id occurred-at-nearmiss --occurred-at "2026-08-29 12:00:00" 2>&1)"
status=$?
nearmiss_inbox="$STORE_DIR/inbox/occurred-at-nearmiss.md"
nearmiss_quarantine="$STORE_DIR/inbox/quarantine/occurred-at-nearmiss.md"
nearmiss_reason="$STORE_DIR/inbox/quarantine/occurred-at-nearmiss.reason.txt"

if [ "$status" -eq 1 ]; then
  pass "occurred_at malformed (near-miss format): normalize-capture.sh exits 1"
else
  fail "occurred_at malformed (near-miss format): normalize-capture.sh exited $status (expected 1)"
fi

if [ ! -e "$nearmiss_inbox" ]; then
  pass "occurred_at malformed (near-miss format): no inbox file written"
else
  fail "occurred_at malformed (near-miss format): an inbox file was written despite malformed occurred_at"
fi

if [ -f "$nearmiss_quarantine" ]; then
  pass "occurred_at malformed (near-miss format): quarantine file exists"
else
  fail "occurred_at malformed (near-miss format): quarantine file missing at $nearmiss_quarantine"
fi

if [ -f "$nearmiss_reason" ] && grep -qi "occurred_at" "$nearmiss_reason"; then
  pass "occurred_at malformed (near-miss format): .reason.txt mentions occurred_at"
else
  fail "occurred_at malformed (near-miss format): .reason.txt missing or does not mention occurred_at"
fi

# --- assertion 3: --hint values land in participant-hints ---
hint_fixture="$CALENDAR_FIXTURES_DIR/calendar-event.json"
if [ -f "$hint_fixture" ]; then
  out="$("$NORMALIZER" "$STORE_DIR" --source "calendar-in/calendar" --type calendar-event --id hint-test \
    --hint "Dana Whitfield" --hint "dana.whitfield@example.com" --file "$hint_fixture" 2>&1)"
  status=$?
  dest="$STORE_DIR/inbox/hint-test.md"

  if [ "$status" -eq 0 ] && [ -f "$dest" ]; then
    if grep -qF '  - "Dana Whitfield"' "$dest" && grep -qF '  - "dana.whitfield@example.com"' "$dest"; then
      pass "--hint values land in participant-hints"
    else
      fail "--hint values missing from participant-hints in $dest"
    fi
  else
    fail "--hint test: normalize-capture.sh did not succeed (status $status): $out"
  fi
else
  fail "hint fixture missing: $hint_fixture"
fi

# --- assertion 4: invalid --type quarantines, exit 1, inbox untouched ---
bad_type_fixture="$GMAIL_FIXTURES_DIR/email-voice-note.json"
out="$("$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type bogus --id invalid-type-test --file "$bad_type_fixture" 2>&1)"
status=$?
inbox_dest="$STORE_DIR/inbox/invalid-type-test.md"
quarantine_dest="$STORE_DIR/inbox/quarantine/invalid-type-test.md"
quarantine_reason="$STORE_DIR/inbox/quarantine/invalid-type-test.reason.txt"

if [ "$status" -eq 1 ]; then
  pass "invalid --type: normalize-capture.sh exits 1"
else
  fail "invalid --type: normalize-capture.sh exited $status (expected 1)"
fi

if [ ! -e "$inbox_dest" ]; then
  pass "invalid --type: original input untouched (no inbox file written)"
else
  fail "invalid --type: an inbox file was written despite invalid type"
fi

if [ -f "$quarantine_dest" ]; then
  pass "invalid --type: quarantine file exists"
else
  fail "invalid --type: quarantine file missing at $quarantine_dest"
fi

if [ -f "$quarantine_reason" ] && grep -qi "invalid type" "$quarantine_reason"; then
  pass "invalid --type: .reason.txt mentions the invalid type"
else
  fail "invalid --type: .reason.txt missing or does not mention the invalid type"
fi

# --- assertion 8 (partial): quarantine never deletes — content matches input ---
if [ -f "$quarantine_dest" ]; then
  if diff -q "$bad_type_fixture" "$quarantine_dest" >/dev/null 2>&1; then
    pass "invalid --type: quarantined content equals input (quarantine never deletes)"
  else
    fail "invalid --type: quarantined content does not match input"
  fi
fi

# --- assertion 5: duplicate --id quarantines the second attempt; first untouched ---
dup_fixture_a="$GMAIL_FIXTURES_DIR/email-voice-note.json"
dup_fixture_b="$GMAIL_FIXTURES_DIR/email-linkedin-notification.json"

out="$("$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type voice-note --id dup-test --file "$dup_fixture_a" 2>&1)"
status=$?
dup_dest="$STORE_DIR/inbox/dup-test.md"

if [ "$status" -eq 0 ] && [ -f "$dup_dest" ]; then
  pass "duplicate --id: first call succeeds"
  first_copy="$(mktemp)"
  cp "$dup_dest" "$first_copy"

  out2="$("$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type transcript --id dup-test --file "$dup_fixture_b" 2>&1)"
  status2=$?

  if [ "$status2" -eq 1 ]; then
    pass "duplicate --id: second call exits 1"
  else
    fail "duplicate --id: second call exited $status2 (expected 1)"
  fi

  if diff -q "$first_copy" "$dup_dest" >/dev/null 2>&1; then
    pass "duplicate --id: first inbox file unmodified after duplicate attempt"
  else
    fail "duplicate --id: first inbox file was modified by the duplicate attempt"
  fi

  dup_quarantine="$STORE_DIR/inbox/quarantine/dup-test.md"
  if [ -f "$dup_quarantine" ]; then
    pass "duplicate --id: second attempt quarantined"
  else
    fail "duplicate --id: second attempt was not quarantined at $dup_quarantine"
  fi

  rm -f "$first_copy"
else
  fail "duplicate --id: first call did not succeed (status $status): $out"
fi

# --- assertion 6: empty body is valid ---
out="$(printf '' | "$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type other --id empty-body-test 2>&1)"
status=$?
empty_dest="$STORE_DIR/inbox/empty-body-test.md"

if [ "$status" -eq 0 ] && [ -f "$empty_dest" ]; then
  pass "empty body: normalize-capture.sh exits 0 and writes inbox file"
  extracted="$(mktemp)"
  extract_body "$empty_dest" > "$extracted"
  if [ ! -s "$extracted" ]; then
    pass "empty body: extracted body is empty"
  else
    fail "empty body: extracted body is not empty"
  fi
  rm -f "$extracted"
else
  fail "empty body: normalize-capture.sh did not succeed (status $status): $out"
fi

# --- assertion 7: malformed-junk.txt as body, valid envelope, still written ---
junk_fixture="$GMAIL_FIXTURES_DIR/malformed-junk.txt"
if [ -f "$junk_fixture" ]; then
  out="$("$NORMALIZER" "$STORE_DIR" --source "$GENERIC_SOURCE" --type other --id malformed-body-test --file "$junk_fixture" 2>&1)"
  status=$?
  junk_dest="$STORE_DIR/inbox/malformed-body-test.md"

  if [ "$status" -eq 0 ] && [ -f "$junk_dest" ]; then
    pass "malformed-junk.txt body: valid envelope is still written (exit 0)"
    extracted="$(mktemp)"
    if extract_body "$junk_dest" > "$extracted" && diff -q "$junk_fixture" "$extracted" >/dev/null 2>&1; then
      pass "malformed-junk.txt body: written verbatim"
    else
      fail "malformed-junk.txt body: not written verbatim"
    fi
    rm -f "$extracted"
  else
    fail "malformed-junk.txt body: normalize-capture.sh did not succeed (status $status): $out"
  fi
else
  fail "malformed-junk.txt fixture missing: $junk_fixture"
fi

# --- regression: slashed --source (e.g. "beeper-in/matrix", the 1.2.0
# <connector>/<lane> convention) with a default (no --id) id must not embed
# the slash in the filename — the write must land as a flat file directly
# under inbox/, and the frontmatter source: field must preserve the original
# slashed value verbatim. ---
slashed_out="$(printf 'hello world\n' | "$NORMALIZER" "$STORE_DIR" --source "beeper-in/matrix" --type chat-message --captured-at 2026-08-29T19:09:33Z 2>&1)"
slashed_status=$?

if [ "$slashed_status" -eq 0 ]; then
  pass "slashed source: normalize-capture.sh exits 0"
else
  fail "slashed source: normalize-capture.sh exited $slashed_status (expected 0): $slashed_out"
fi

if [ "$slashed_status" -eq 0 ] && [ -f "$slashed_out" ]; then
  pass "slashed source: printed path exists on disk"
else
  fail "slashed source: printed path does not exist on disk (printed: $slashed_out)"
fi

if [ "$slashed_status" -eq 0 ]; then
  slashed_dirname="$(dirname "$slashed_out")"
  slashed_basename="$(basename "$slashed_out")"
  if [ "$slashed_dirname" = "$STORE_DIR/inbox" ]; then
    pass "slashed source: file lands directly under inbox/ (no nonexistent intermediate dir)"
  else
    fail "slashed source: file did not land directly under inbox/ (got dirname: $slashed_dirname)"
  fi

  case "$slashed_basename" in
    *beeper-in-matrix*)
      pass "slashed source: flat filename contains sanitized 'beeper-in-matrix'"
      ;;
    *)
      fail "slashed source: flat filename does not contain sanitized 'beeper-in-matrix' (got: $slashed_basename)"
      ;;
  esac

  if grep -qF "source: beeper-in/matrix" "$slashed_out"; then
    pass "slashed source: frontmatter source preserves 'beeper-in/matrix' verbatim"
  else
    fail "slashed source: frontmatter source does not preserve 'beeper-in/matrix' verbatim in $slashed_out"
  fi
else
  fail "slashed source: skipped downstream checks (normalizer did not succeed)"
fi

# --- gmail-in/scripts/classify.sh: typing rules (subject + From-address ->
# voice-note / linkedin-notification / email), per the plan-17 mapping
# table. Deterministic, offline, no normalize-capture.sh involvement. ---

classify_check() {
  # $1 = label, $2 = subject, $3 = from-address, $4 = expected type
  label="$1"
  subject="$2"
  from_addr="$3"
  expected="$4"
  got="$("$CLASSIFY" "$subject" "$from_addr" 2>&1)"
  cstatus=$?
  if [ "$cstatus" -eq 0 ] && [ "$got" = "$expected" ]; then
    pass "classify.sh: $label -> $expected"
  else
    fail "classify.sh: $label expected '$expected', got '$got' (exit $cstatus)"
  fi
}

classify_check "[ra] subject" "debrief: coffee with dana [ra]" "Me <me@example.com>" "voice-note"
classify_check "linkedin.com From" "Priya Nair viewed your profile" "LinkedIn <notifications-noreply@linkedin.com>" "linkedin-notification"
classify_check "subdomain of linkedin.com From" "You have a new connection" "LinkedIn <notifications@e.linkedin.com>" "linkedin-notification"
classify_check "[ra] subject + linkedin.com From together (precedence)" "debrief: call with dana [ra]" "LinkedIn <notifications-noreply@linkedin.com>" "voice-note"
classify_check "plain subject and From" "Re: fintech partnerships sync" "Dana Whitfield <dana.whitfield@example.com>" "email"

# --- calendar-in/scripts/extract-hints.sh: organizer + creator + every
# attendee present in the output, correct "Name <email>" / bare-email
# fallback forms, no self-filtering (the self: true attendee appears). ---

hint_output="$("$EXTRACT_HINTS" < "$CALENDAR_FIXTURES_DIR/calendar-event.json" 2>&1)"
hint_status=$?

if [ "$hint_status" -eq 0 ]; then
  pass "extract-hints.sh: exits 0 against calendar-event.json"
else
  fail "extract-hints.sh: exited $hint_status against calendar-event.json: $hint_output"
fi

# calendar-event.json fixture: organizer == creator == dana.whitfield (no
# displayName, per fixtures/README.md — bare-email fallback form expected);
# attendees: dana.whitfield (organizer:true), user@example.com (self:true),
# priya.nair, guest — all bare email, no displayName present anywhere.
if printf '%s\n' "$hint_output" | grep -qxF "dana.whitfield@example.org"; then
  pass "extract-hints.sh: organizer/creator (dana.whitfield, bare-email fallback) present"
else
  fail "extract-hints.sh: organizer/creator (dana.whitfield) missing from output: $hint_output"
fi

organizer_creator_count="$(printf '%s\n' "$hint_output" | grep -cxF "dana.whitfield@example.org")"
if [ "$organizer_creator_count" -ge 3 ]; then
  pass "extract-hints.sh: dana.whitfield appears for organizer, creator, AND the matching attendee entry (>= 3 lines)"
else
  fail "extract-hints.sh: expected >= 3 lines for dana.whitfield (organizer + creator + attendee), got $organizer_creator_count: $hint_output"
fi

if printf '%s\n' "$hint_output" | grep -qxF "user@example.com"; then
  pass "extract-hints.sh: self: true attendee (user@example.com) is present — no self-filtering"
else
  fail "extract-hints.sh: self: true attendee (user@example.com) missing — should never be filtered: $hint_output"
fi

if printf '%s\n' "$hint_output" | grep -qxF "priya.nair@example.com"; then
  pass "extract-hints.sh: non-organizer attendee (priya.nair) present"
else
  fail "extract-hints.sh: non-organizer attendee (priya.nair) missing: $hint_output"
fi

if printf '%s\n' "$hint_output" | grep -qxF "guest@example.com"; then
  pass "extract-hints.sh: non-organizer attendee (guest) present"
else
  fail "extract-hints.sh: non-organizer attendee (guest) missing: $hint_output"
fi

# ---------------------------------------------------------------------------
# backfill checkpoint isolation (deferred out of scope for the gmail-in /
# calendar-in lanes per the plan-17 "Out of scope" section — backfill mode
# is not ported in this chunk). This block exercises the generic
# ledger-isolation write
# pattern the plan's carried-over "Ledger discipline" section describes
# (an incremental checkpoint/processed.log pair must never be touched by a
# backfill batch's writes), independent of any specific connector, so it
# stays as regression coverage for whichever lane later re-adds backfill
# mode.
# ---------------------------------------------------------------------------

CONNECTOR_STATE_DIR="$(mktemp -d)"
GMAIL_STATE="$CONNECTOR_STATE_DIR/gmail"
mkdir -p "$GMAIL_STATE"

INCREMENTAL_CHECKPOINT="$GMAIL_STATE/checkpoint"
INCREMENTAL_LOG="$GMAIL_STATE/processed.log"
BACKFILL_CHECKPOINT="$GMAIL_STATE/backfill-checkpoint"
BACKFILL_LOG="$GMAIL_STATE/backfill-processed.log"

printf '2026-08-01T00:00:00Z\n' > "$INCREMENTAL_CHECKPOINT"
printf 'msg-already-incremental\n' > "$INCREMENTAL_LOG"

incremental_checkpoint_before="$(mktemp)"
incremental_log_before="$(mktemp)"
cp "$INCREMENTAL_CHECKPOINT" "$incremental_checkpoint_before"
cp "$INCREMENTAL_LOG" "$incremental_log_before"

# simulate a backfill batch: two new message ids, one of which duplicates an
# already-incrementally-captured id (must be skipped via read-only dedup
# against processed.log, never written to it).
simulate_backfill_batch() {
  batch_ids="msg-already-incremental msg-backfill-only-1 msg-backfill-only-2"
  for msg_id in $batch_ids; do
    if grep -qxF "$msg_id" "$INCREMENTAL_LOG" 2>/dev/null; then
      continue  # already captured incrementally — skip, never re-write processed.log
    fi
    if grep -qxF "$msg_id" "$BACKFILL_LOG" 2>/dev/null; then
      continue  # already captured by a prior backfill pass
    fi
    printf '%s\n' "$msg_id" >> "$BACKFILL_LOG"
  done
  printf '2025-08-01T00:00:00Z\n' > "$BACKFILL_CHECKPOINT"
}

simulate_backfill_batch

if diff -q "$incremental_checkpoint_before" "$INCREMENTAL_CHECKPOINT" >/dev/null 2>&1; then
  pass "backfill isolation: incremental checkpoint file byte-identical after backfill batch"
else
  fail "backfill isolation: incremental checkpoint file was modified by backfill"
fi

if diff -q "$incremental_log_before" "$INCREMENTAL_LOG" >/dev/null 2>&1; then
  pass "backfill isolation: incremental processed.log byte-identical after backfill batch (read-only dedup)"
else
  fail "backfill isolation: incremental processed.log was modified by backfill"
fi

if [ -f "$BACKFILL_CHECKPOINT" ] && [ -f "$BACKFILL_LOG" ]; then
  pass "backfill isolation: backfill-namespace files were created"
else
  fail "backfill isolation: backfill-namespace files missing"
fi

if grep -qxF "msg-backfill-only-1" "$BACKFILL_LOG" 2>/dev/null && grep -qxF "msg-backfill-only-2" "$BACKFILL_LOG" 2>/dev/null; then
  pass "backfill isolation: new message ids landed in backfill-processed.log"
else
  fail "backfill isolation: expected new message ids missing from backfill-processed.log"
fi

if grep -qxF "msg-already-incremental" "$BACKFILL_LOG" 2>/dev/null; then
  fail "backfill isolation: an already-incrementally-captured id was duplicated into backfill-processed.log"
else
  pass "backfill isolation: an already-incrementally-captured id was correctly skipped, not duplicated"
fi

rm -rf "$CONNECTOR_STATE_DIR" "$incremental_checkpoint_before" "$incremental_log_before"

# ---------------------------------------------------------------------------
# resolve-backfill-window.sh (packages/connectors/scripts/resolve-backfill-window.sh,
# plan 24 U3/U10) — window resolution for onboarding backfill mode, per
# packages/core/contracts/onboarding-backfill.md.
# ---------------------------------------------------------------------------

RESOLVE_WINDOW="$REPO_ROOT/packages/connectors/scripts/resolve-backfill-window.sh"

if [ ! -f "$RESOLVE_WINDOW" ]; then
  echo "SKIP: $RESOLVE_WINDOW not found — cannot run resolve-backfill-window.sh tests."
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  RBW_DATA_DIR="$(mktemp -d)"

  # (a) missing config file -> exit 0, default window_months of 6
  out="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1)"
  status=$?
  months="$(printf '%s' "$out" | cut -f2)"
  if [ "$status" -eq 0 ] && [ "$months" = "6" ]; then
    pass "resolve-backfill-window: missing config file defaults to window_months 6"
  else
    fail "resolve-backfill-window: missing config file did not default to 6 (status $status, out: $out)"
  fi

  # (b) window_months=2 -> second field 2, window_start ~ now-2 months
  mkdir -p "$RBW_DATA_DIR/config"
  printf 'window_months\t2\n' > "$RBW_DATA_DIR/config/onboarding-backfill.tsv"
  out="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1)"
  status=$?
  window_start="$(printf '%s' "$out" | cut -f1)"
  months="$(printf '%s' "$out" | cut -f2)"
  expected_prefix="$(date -u -v-2m +%Y-%m)"
  if [ "$status" -eq 0 ] && [ "$months" = "2" ] && [ "${window_start%%-??T*}" = "$expected_prefix" ]; then
    pass "resolve-backfill-window: window_months=2 resolves to months=2 and window_start ~ now-2mo"
  else
    fail "resolve-backfill-window: window_months=2 case failed (status $status, out: $out, expected prefix $expected_prefix)"
  fi

  # (c) malformed row (no tab) -> non-zero exit, non-empty stderr, empty stdout
  printf 'not-a-valid-row-no-tab\n' > "$RBW_DATA_DIR/config/onboarding-backfill.tsv"
  status=0
  "$RESOLVE_WINDOW" "$RBW_DATA_DIR" >/dev/null 2>/dev/null || status=$?
  err="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1 1>/dev/null)"
  stdout_only="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>/dev/null)"
  if [ "$status" -ne 0 ] && [ -n "$err" ] && [ -z "$stdout_only" ]; then
    pass "resolve-backfill-window: malformed row (no tab) fails closed (non-zero, stderr, no stdout)"
  else
    fail "resolve-backfill-window: malformed row (no tab) did not fail closed (status $status, err: $err, stdout: $stdout_only)"
  fi

  # (d) unknown key -> non-zero exit, non-empty stderr, empty stdout
  printf 'bogus_key\tvalue\n' > "$RBW_DATA_DIR/config/onboarding-backfill.tsv"
  status=0
  "$RESOLVE_WINDOW" "$RBW_DATA_DIR" >/dev/null 2>/dev/null || status=$?
  err="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1 1>/dev/null)"
  stdout_only="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>/dev/null)"
  if [ "$status" -ne 0 ] && [ -n "$err" ] && [ -z "$stdout_only" ]; then
    pass "resolve-backfill-window: unknown key fails closed (non-zero, stderr, no stdout)"
  else
    fail "resolve-backfill-window: unknown key did not fail closed (status $status, err: $err, stdout: $stdout_only)"
  fi

  # (e) window_months=0 -> non-zero exit, non-empty stderr, empty stdout
  printf 'window_months\t0\n' > "$RBW_DATA_DIR/config/onboarding-backfill.tsv"
  status=0
  "$RESOLVE_WINDOW" "$RBW_DATA_DIR" >/dev/null 2>/dev/null || status=$?
  err="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1 1>/dev/null)"
  stdout_only="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>/dev/null)"
  if [ "$status" -ne 0 ] && [ -n "$err" ] && [ -z "$stdout_only" ]; then
    pass "resolve-backfill-window: window_months=0 fails closed (non-zero, stderr, no stdout)"
  else
    fail "resolve-backfill-window: window_months=0 did not fail closed (status $status, err: $err, stdout: $stdout_only)"
  fi

  # (f) self rows + comments + window_months=3 -> exit 0, months=3
  cat > "$RBW_DATA_DIR/config/onboarding-backfill.tsv" <<'EOF'
# onboarding backfill config
self	me@example.com
self	me-alt@example.com

window_months	3
EOF
  out="$("$RESOLVE_WINDOW" "$RBW_DATA_DIR" 2>&1)"
  status=$?
  months="$(printf '%s' "$out" | cut -f2)"
  if [ "$status" -eq 0 ] && [ "$months" = "3" ]; then
    pass "resolve-backfill-window: self rows + comments + window_months=3 resolves to months=3"
  else
    fail "resolve-backfill-window: self rows + comments + window_months=3 case failed (status $status, out: $out)"
  fi

  rm -rf "$RBW_DATA_DIR"
fi

# ---------------------------------------------------------------------------
# calendar-in backfill ledger isolation (plan 24 D5, calendar-sweep SKILL.md
# "Backfill mode" §8 adaptation): dedup reads BOTH processed.log (incremental)
# and backfill-processed.log (backfill), keyed <event-id>:<updated>; a
# successful backfill capture appends ONLY to backfill-processed.log, never
# touching processed.log. calendar-sweep is session-driven (no standalone
# script), so this simulates the documented dedup/append rules the same way
# the gmail-in namespace-isolation block above does.
# ---------------------------------------------------------------------------

CAL_STATE_DIR="$(mktemp -d)"
CAL_STATE="$CAL_STATE_DIR/calendar"
mkdir -p "$CAL_STATE"

CAL_INCREMENTAL_LOG="$CAL_STATE/processed.log"
CAL_BACKFILL_LOG="$CAL_STATE/backfill-processed.log"

printf 'evt-already-incremental:2026-08-01T00:00:00Z\n' > "$CAL_INCREMENTAL_LOG"

cal_incremental_log_before="$(mktemp)"
cp "$CAL_INCREMENTAL_LOG" "$cal_incremental_log_before"

# simulate a backfill pass: one dedup key already in the incremental ledger,
# one already in a prior backfill pass's ledger, two genuinely new keys.
simulate_calendar_backfill_pass() {
  target_log="$1"
  printf 'evt-already-in-backfill:2026-07-01T00:00:00Z\n' > "$CAL_BACKFILL_LOG"
  batch_keys="evt-already-incremental:2026-08-01T00:00:00Z evt-already-in-backfill:2026-07-01T00:00:00Z evt-backfill-only-1:2026-06-01T00:00:00Z evt-backfill-only-2:2026-05-01T00:00:00Z"
  for dedup_key in $batch_keys; do
    if grep -qxF "$dedup_key" "$CAL_INCREMENTAL_LOG" 2>/dev/null; then
      continue  # already captured incrementally — skip, dedup read-only
    fi
    if grep -qxF "$dedup_key" "$CAL_BACKFILL_LOG" 2>/dev/null; then
      continue  # already captured by a prior backfill pass
    fi
    printf '%s\n' "$dedup_key" >> "$target_log"
  done
}

simulate_calendar_backfill_pass "$CAL_BACKFILL_LOG"

if grep -qxF "evt-backfill-only-1:2026-06-01T00:00:00Z" "$CAL_BACKFILL_LOG" 2>/dev/null \
  && grep -qxF "evt-backfill-only-2:2026-05-01T00:00:00Z" "$CAL_BACKFILL_LOG" 2>/dev/null; then
  pass "calendar backfill ledger: new dedup keys appended to backfill-processed.log"
else
  fail "calendar backfill ledger: expected new dedup keys missing from backfill-processed.log"
fi

if grep -qxF "evt-already-incremental:2026-08-01T00:00:00Z" "$CAL_BACKFILL_LOG" 2>/dev/null; then
  fail "calendar backfill ledger: a key already in processed.log was duplicated into backfill-processed.log (dedup must check both ledgers)"
else
  pass "calendar backfill ledger: a key already in processed.log was correctly skipped (dedup checks both ledgers)"
fi

cal_dup_count="$(grep -cxF "evt-already-in-backfill:2026-07-01T00:00:00Z" "$CAL_BACKFILL_LOG" 2>/dev/null)"
if [ "$cal_dup_count" -eq 1 ]; then
  pass "calendar backfill ledger: a key already in backfill-processed.log was not re-appended (dedup checks its own ledger too)"
else
  fail "calendar backfill ledger: a key already in backfill-processed.log was duplicated ($cal_dup_count occurrences)"
fi

if diff -q "$cal_incremental_log_before" "$CAL_INCREMENTAL_LOG" >/dev/null 2>&1; then
  pass "calendar backfill ledger: incremental processed.log byte-identical after backfill pass"
else
  fail "calendar backfill ledger: incremental processed.log was modified by a backfill pass"
fi

rm -rf "$CAL_STATE_DIR" "$cal_incremental_log_before"

# ---------------------------------------------------------------------------
# gmail-in/scripts/extract-email-body.sh (plan 26 U8) — pulls one message's
# body out of a saved get_thread/get_message result file, per the script's
# own header comment: "Subject: <subject>" + blank line + verbatim
# plaintextBody, byte-exact, no trailing-newline mangling.
# ---------------------------------------------------------------------------

# --- byte-exact extraction from a get_thread-shape fixture (messages[]
# array); the target message's plaintextBody carries trailing spaces, a
# blank line, and a trailing newline, so trailing-newline mangling would
# show up as a byte diff. ---
thread_fixture="$GMAIL_FIXTURES_DIR/get-thread-result.json"
expected_body_out="$(mktemp)"
printf 'Subject: Re: proposal draft\n\nConfirmed for Tuesday.  \n\nTalk soon.\n' > "$expected_body_out"

actual_body_out="$(mktemp)"
"$EXTRACT_BODY_SCRIPT" "$thread_fixture" "18f2a3b9c0d1e402" > "$actual_body_out" 2>/dev/null
extract_status=$?

if [ "$extract_status" -eq 0 ]; then
  pass "extract-email-body.sh: exits 0 for a present message id"
else
  fail "extract-email-body.sh: exited $extract_status for a present message id (expected 0)"
fi

if cmp -s "$expected_body_out" "$actual_body_out"; then
  pass "extract-email-body.sh: subject + blank line + plaintextBody is byte-exact (cmp)"
else
  fail "extract-email-body.sh: output is not byte-exact vs expected (od -c to diagnose): $(od -c "$actual_body_out" | head -n 5)"
fi

rm -f "$expected_body_out" "$actual_body_out"

# --- absent message id: non-zero exit, a stderr reason, no stdout ---
absent_status=0
"$EXTRACT_BODY_SCRIPT" "$thread_fixture" "nonexistent-message-id-xyz" >/dev/null 2>/dev/null || absent_status=$?
absent_stderr="$("$EXTRACT_BODY_SCRIPT" "$thread_fixture" "nonexistent-message-id-xyz" 2>&1 1>/dev/null)"
absent_stdout="$(mktemp)"
"$EXTRACT_BODY_SCRIPT" "$thread_fixture" "nonexistent-message-id-xyz" >"$absent_stdout" 2>/dev/null

if [ "$absent_status" -ne 0 ]; then
  pass "extract-email-body.sh: absent message id exits non-zero"
else
  fail "extract-email-body.sh: absent message id exited 0 (expected non-zero)"
fi

if [ -n "$absent_stderr" ]; then
  pass "extract-email-body.sh: absent message id prints a stderr reason"
else
  fail "extract-email-body.sh: absent message id printed no stderr reason"
fi

if [ ! -s "$absent_stdout" ]; then
  pass "extract-email-body.sh: absent message id emits no stdout"
else
  fail "extract-email-body.sh: absent message id emitted stdout despite the miss"
fi

rm -f "$absent_stdout"

# --- toRecipients absent entirely (live-verified absent-not-empty shape):
# extraction still succeeds, no crash, subject + plaintextBody are correct. ---
no_recipients_fixture="$GMAIL_FIXTURES_DIR/email-no-recipients.json"
if [ -f "$no_recipients_fixture" ]; then
  no_recip_out="$("$EXTRACT_BODY_SCRIPT" "$no_recipients_fixture" "18f2a3b9c0d1e420" 2>&1)"
  no_recip_status=$?

  if [ "$no_recip_status" -eq 0 ]; then
    pass "extract-email-body.sh: toRecipients-absent message extracts without crashing (exit 0)"
  else
    fail "extract-email-body.sh: toRecipients-absent message failed (status $no_recip_status): $no_recip_out"
  fi

  expected_no_recip="Subject: Weekly digest

Your weekly digest is ready. Nothing new from your contacts this week."
  if [ "$no_recip_out" = "$expected_no_recip" ]; then
    pass "extract-email-body.sh: toRecipients-absent message subject + body correct"
  else
    fail "extract-email-body.sh: toRecipients-absent message output mismatch (got: $no_recip_out)"
  fi
else
  fail "toRecipients-absent fixture missing: $no_recipients_fixture"
fi

# --- duplicate message id (plan 27 R2): the target id appears twice in
# messages[]; the first(...) guard must yield exactly the first match's
# Subject+body, byte-exact, not a concatenation of both matches. ---
dup_id_fixture="$GMAIL_FIXTURES_DIR/get-thread-result-dup-id.json"
if [ -f "$dup_id_fixture" ]; then
  expected_dup_out="$(mktemp)"
  printf 'Subject: Re: proposal draft\n\nConfirmed for Tuesday.  \n\nTalk soon.\n' > "$expected_dup_out"

  actual_dup_out="$(mktemp)"
  "$EXTRACT_BODY_SCRIPT" "$dup_id_fixture" "18f2a3b9c0d1e402" > "$actual_dup_out" 2>/dev/null
  dup_status=$?

  if [ "$dup_status" -eq 0 ]; then
    pass "extract-email-body.sh: duplicated message id exits 0"
  else
    fail "extract-email-body.sh: duplicated message id exited $dup_status (expected 0)"
  fi

  if cmp -s "$expected_dup_out" "$actual_dup_out"; then
    pass "extract-email-body.sh: duplicated message id yields the first match only, byte-exact (cmp)"
  else
    fail "extract-email-body.sh: duplicated message id output is not the first match's body alone (od -c to diagnose): $(od -c "$actual_dup_out" | head -n 5)"
  fi

  rm -f "$expected_dup_out" "$actual_dup_out"
else
  fail "duplicate-message-id fixture missing: $dup_id_fixture"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
