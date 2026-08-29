#!/usr/bin/env bash
# packages/connectors/tests/run-capture-tests.sh
#
# Asserts that packages/connectors/scripts/normalize-capture.sh, the shared
# capture normalizer, behaves correctly against the composio-in fixture pack
# (packages/connectors/composio-in/fixtures/), per
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
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere. Uses a throwaway mktemp -d store,
# cleaned up on exit via trap.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

NORMALIZER="$REPO_ROOT/packages/connectors/scripts/normalize-capture.sh"
FIXTURES_DIR="$REPO_ROOT/packages/connectors/composio-in/fixtures"

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

# --- normalizer must exist ---
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

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "FAIL: fixtures dir missing at $FIXTURES_DIR"
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

# --- assertion 1 & 2: each valid fixture normalizes correctly, body verbatim ---
fixture_specs="
email-voice-note.json:voice-note
email-linkedin-notification.json:other
calendar-event.json:other
linkedin-post.json:other
"

# `<<<` (here-string) runs the loop in the current shell under bash 3.2
# (unlike piping into `while`, which forks a subshell), so PASS_COUNT/
# FAIL_COUNT updates inside the loop are visible afterward.
while IFS=':' read -r fname ftype; do
  [ -z "$fname" ] && continue

  fixture_path="$FIXTURES_DIR/$fname"
  stem="${fname%.*}"

  if [ ! -f "$fixture_path" ]; then
    fail "fixture missing: $fixture_path"
    continue
  fi

  out="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type "$ftype" --id "$stem" --file "$fixture_path" 2>&1)"
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

    if grep -qF "source: composio-in" "$dest"; then
      pass "$fname: frontmatter source is composio-in"
    else
      fail "$fname: frontmatter source is not composio-in"
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
done <<< "$fixture_specs"

# --- enum coverage: no fixture above exercises these types directly (the
# sweeps only ever emit voice-note/other today; linkedin-notification,
# event-confirmation, and transcript are reserved for a later filing chunk)
# — assert the normalizer still accepts each of them with a trivial body ---
remaining_enum_types="
linkedin-notification
event-confirmation
transcript
"

while IFS= read -r etype; do
  [ -z "$etype" ] && continue

  eid="enum-coverage-$etype"
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type "$etype" --id "$eid" 2>&1)"
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
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type "$netype" --id "$neid" 2>&1)"
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
  out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type "$cetype" --id "$ceid" 2>&1)"
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
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type email --id occurred-at-valid --occurred-at 2026-08-29T12:00:00Z 2>&1)"
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
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type email --id occurred-at-absent 2>&1)"
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
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type email --id occurred-at-malformed --occurred-at not-a-date 2>&1)"
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
out="$(printf 'trivial body' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type email --id occurred-at-nearmiss --occurred-at "2026-08-29 12:00:00" 2>&1)"
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
hint_fixture="$FIXTURES_DIR/calendar-event.json"
if [ -f "$hint_fixture" ]; then
  out="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type event-confirmation --id hint-test \
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
bad_type_fixture="$FIXTURES_DIR/email-voice-note.json"
out="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type bogus --id invalid-type-test --file "$bad_type_fixture" 2>&1)"
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
dup_fixture_a="$FIXTURES_DIR/email-voice-note.json"
dup_fixture_b="$FIXTURES_DIR/email-linkedin-notification.json"

out="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type voice-note --id dup-test --file "$dup_fixture_a" 2>&1)"
status=$?
dup_dest="$STORE_DIR/inbox/dup-test.md"

if [ "$status" -eq 0 ] && [ -f "$dup_dest" ]; then
  pass "duplicate --id: first call succeeds"
  first_copy="$(mktemp)"
  cp "$dup_dest" "$first_copy"

  out2="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type transcript --id dup-test --file "$dup_fixture_b" 2>&1)"
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
out="$(printf '' | "$NORMALIZER" "$STORE_DIR" --source composio-in --type other --id empty-body-test 2>&1)"
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
junk_fixture="$FIXTURES_DIR/malformed-junk.txt"
if [ -f "$junk_fixture" ]; then
  out="$("$NORMALIZER" "$STORE_DIR" --source composio-in --type other --id malformed-body-test --file "$junk_fixture" 2>&1)"
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

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
