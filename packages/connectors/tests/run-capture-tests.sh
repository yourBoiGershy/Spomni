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

# --- backfill checkpoint isolation (composio-in gmail-sweep/calendar-sweep
# backfill mode, per packages/connectors/composio-in/skills/gmail-sweep/SKILL.md
# and calendar-sweep/SKILL.md's "Backfill mode" sections) ---
#
# No live Composio calls here — this simulates the write path the skills
# describe: pre-seed an incremental checkpoint + processed.log, run a
# simulated backfill batch, then assert the incremental checkpoint file is
# byte-identical afterward and only backfill-namespace files were written.

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

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
