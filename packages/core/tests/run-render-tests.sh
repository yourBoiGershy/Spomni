#!/bin/bash
# packages/core/tests/run-render-tests.sh
#
# Asserts:
#   1-7. packages/core/scripts/render-nudge-cards.sh renders one fired
#        wake-up batch into the no-guilt plain-text chat message (contract
#        packages/core/contracts/nudge-card.md 1.0.0), against the fixture
#        at packages/core/fixtures/fired-batch/.
#   8-12. packages/core/scripts/validate-store.sh's Pass 1.5 `## Notify`
#        section rules (channel/beeper_chat_id/quiet_hours/gmail_address,
#        [stated-by-user]-only, enum + grammar checks).
#
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RENDERER="$REPO_ROOT/packages/core/scripts/render-nudge-cards.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURE_DIR="$REPO_ROOT/packages/core/fixtures/fired-batch"
BATCH="$FIXTURE_DIR/batch.json"
EXPECTED="$FIXTURE_DIR/expected.txt"

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

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- renderer must exist ---
if [ ! -x "$RENDERER" ]; then
  echo "SKIP: $RENDERER not found or not executable — cannot run render tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, renderer missing"
  exit 1
fi

if [ ! -f "$BATCH" ] || [ ! -f "$EXPECTED" ]; then
  fail "fired-batch fixture missing (expected $BATCH and $EXPECTED)"
else
  # --- assertion 1: fixture render is byte-equal to expected.txt ---
  render_out="$TMP_ROOT/render-out.txt"
  "$RENDERER" "$BATCH" > "$render_out" 2>"$TMP_ROOT/render-err.txt"
  render_status=$?
  if [ "$render_status" -ne 0 ]; then
    fail "render-nudge-cards.sh exited $render_status (expected 0) on the fixture batch"
    cat "$TMP_ROOT/render-err.txt"
  else
    if diff -q "$EXPECTED" "$render_out" > /dev/null 2>&1; then
      pass "render-nudge-cards.sh output is byte-equal to fixtures/fired-batch/expected.txt"
    else
      fail "render-nudge-cards.sh output differs from expected.txt"
      diff "$EXPECTED" "$render_out"
    fi
  fi

  # --- assertion 2: numbering follows entries order ---
  # Reverse the entries so what was entry 3 (jordan-lee, "quarterly
  # catch-up is due") becomes entry 1 in the numbering.
  reversed_batch="$TMP_ROOT/reversed-batch.json"
  jq '.entries |= reverse' "$BATCH" > "$reversed_batch"
  reversed_out="$("$RENDERER" "$reversed_batch" 2>"$TMP_ROOT/reversed-err.txt")"
  reversed_status=$?
  if [ "$reversed_status" -ne 0 ]; then
    fail "render-nudge-cards.sh exited $reversed_status (expected 0) on the reversed batch"
    cat "$TMP_ROOT/reversed-err.txt"
  else
    first_line="$(printf '%s\n' "$reversed_out" | head -n1)"
    if [ "$first_line" = "1. quarterly catch-up is due" ]; then
      pass "numbering follows entries[] order (reversed batch: former 3rd entry is now '1.')"
    else
      fail "numbering did not follow entries[] order on the reversed batch, got first line: $first_line"
    fi
  fi

  # --- assertion 3: 'Draft (unsent):' appears exactly once ---
  draft_count="$(printf '%s' "$(cat "$render_out")" | grep -c '^Draft (unsent):$')"
  if [ "$draft_count" -eq 1 ]; then
    pass "'Draft (unsent):' appears exactly once in the fixture render"
  else
    fail "'Draft (unsent):' appeared $draft_count times (expected 1)"
  fi

  # --- assertion 4: no-guilt language never appears ---
  if grep -qiE 'pending|missed|overdue|held|budget' "$render_out"; then
    fail "render output contains no-guilt-violating language (pending|missed|overdue|held|budget)"
    grep -inE 'pending|missed|overdue|held|budget' "$render_out"
  else
    pass "render output contains none of pending|missed|overdue|held|budget (no-guilt list)"
  fi

  # --- assertion 5: mention line is un-numbered ---
  mention_line="$(grep -F 'You never debriefed' "$render_out")"
  if [ -z "$mention_line" ]; then
    fail "mention line ('You never debriefed ...') not found in render output"
  elif printf '%s' "$mention_line" | grep -qE '^[0-9]+\.'; then
    fail "mention line is numbered (expected un-numbered), got: $mention_line"
  else
    pass "mention line is un-numbered"
  fi

  # --- assertion 6: empty entries -> exit 3, empty stdout ---
  empty_batch="$TMP_ROOT/empty-batch.json"
  jq '.entries = []' "$BATCH" > "$empty_batch"
  empty_out="$("$RENDERER" "$empty_batch" 2>/dev/null)"
  empty_status=$?
  if [ "$empty_status" -eq 3 ] && [ -z "$empty_out" ]; then
    pass "empty entries[] -> exit 3 with empty stdout"
  else
    fail "empty entries[] gave exit $empty_status and stdout '$empty_out' (expected exit 3, empty stdout)"
  fi

  # --- assertion 7: footer is the exact reply-grammar line ---
  expected_footer='Reply with the number: <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>'
  actual_footer="$(tail -n1 "$render_out")"
  if [ "$actual_footer" = "$expected_footer" ]; then
    pass "last line is the exact reply-grammar footer"
  else
    fail "last line did not match the reply-grammar footer"
    echo "  expected: $expected_footer"
    echo "  actual:   $actual_footer"
  fi

  # --- assertion: mixed bare/bracketed people slugs render as [[slug]] once ---
  mixed_batch="$TMP_ROOT/mixed-people-batch.json"
  jq '.entries[0].people = ["dana-whitfield", "[[sam-okafor]]"]' "$BATCH" > "$mixed_batch"
  mixed_out="$("$RENDERER" "$mixed_batch" 2>"$TMP_ROOT/mixed-err.txt")"
  mixed_status=$?
  if [ "$mixed_status" -ne 0 ]; then
    fail "render-nudge-cards.sh exited $mixed_status (expected 0) on the mixed bare/bracketed people batch"
    cat "$TMP_ROOT/mixed-err.txt"
  else
    quad_bracket_count="$(printf '%s\n' "$mixed_out" | grep -c '\[\[\[\[')"
    if [ "$quad_bracket_count" -eq 0 ] && printf '%s\n' "$mixed_out" | grep -qF '[[dana-whitfield]], [[sam-okafor]]'; then
      pass "mixed bare and already-bracketed people slugs each render exactly as [[slug]] once"
    else
      fail "mixed bare/bracketed people slugs did not render correctly (quad-bracket count: $quad_bracket_count)"
      printf '%s\n' "$mixed_out" | head -n2
    fi
  fi

  # --- assertion bad file: nonexistent/invalid JSON -> exit 2 ---
  bad_out="$("$RENDERER" "$TMP_ROOT/does-not-exist.json" 2>/dev/null)"
  bad_status=$?
  if [ "$bad_status" -eq 2 ]; then
    pass "missing batch file -> exit 2"
  else
    fail "missing batch file gave exit $bad_status (expected 2)"
  fi
fi

# ---------------------------------------------------------------------------
# assertions 8-12: validate-store.sh Pass 1.5 '## Notify' section rules
# ---------------------------------------------------------------------------

if [ ! -x "$VALIDATOR" ]; then
  fail "$VALIDATOR not found or not executable — cannot run Notify validator tests"
else
  build_notify_store() {
    # $1 = target dir, $2 = Notify section body (bullets, one per line)
    local dir="$1"
    local body="$2"
    mkdir -p "$dir/people" "$dir/interactions" "$dir/wakeups"
    cat > "$dir/profile.md" <<EOF
---
schema_version: 1.1.0
---

## Priorities

## Cadence wishes

## Signal opt-outs

## Style notes

## Notify

$body
EOF
  }

  # --- assertion 8: valid Notify section -> clean (exit 0) ---
  valid_store="$TMP_ROOT/notify-valid"
  build_notify_store "$valid_store" '- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: chat-abc123 (2026-08-30)
- **[stated-by-user]** quiet_hours: 22:00-08:00 (2026-08-30)
- **[stated-by-user]** gmail_address: eric@example.com (2026-08-30)'
  valid_out="$("$VALIDATOR" "$valid_store" 2>&1)"
  valid_status=$?
  if [ "$valid_status" -eq 0 ]; then
    pass "validate-store.sh exits 0 on a store with a valid Notify section"
  else
    fail "validate-store.sh exited $valid_status (expected 0) on a valid Notify section"
    echo "$valid_out"
  fi

  # --- assertion 9: bad channel enum -> error (exit 1) ---
  bad_channel_store="$TMP_ROOT/notify-bad-channel"
  build_notify_store "$bad_channel_store" '- **[stated-by-user]** channel: telegram-self (2026-08-30)'
  bad_channel_out="$("$VALIDATOR" "$bad_channel_store" 2>&1)"
  bad_channel_status=$?
  if [ "$bad_channel_status" -eq 1 ] && printf '%s' "$bad_channel_out" | grep -qi "channel value invalid"; then
    pass "validate-store.sh rejects a Notify channel outside the enum"
  else
    fail "validate-store.sh gave exit $bad_channel_status (expected 1, with 'channel value invalid') for bad channel enum"
    echo "$bad_channel_out"
  fi

  # --- assertion 10: bad quiet_hours -> error (exit 1) ---
  bad_quiet_store="$TMP_ROOT/notify-bad-quiet-hours"
  build_notify_store "$bad_quiet_store" '- **[stated-by-user]** quiet_hours: 25:99-08:00 (2026-08-30)'
  bad_quiet_out="$("$VALIDATOR" "$bad_quiet_store" 2>&1)"
  bad_quiet_status=$?
  if [ "$bad_quiet_status" -eq 1 ] && printf '%s' "$bad_quiet_out" | grep -qi "quiet_hours value malformed"; then
    pass "validate-store.sh rejects a malformed Notify quiet_hours value"
  else
    fail "validate-store.sh gave exit $bad_quiet_status (expected 1, with 'quiet_hours value malformed') for bad quiet_hours"
    echo "$bad_quiet_out"
  fi

  # --- assertion 11: untagged bullet -> error (exit 1) ---
  untagged_store="$TMP_ROOT/notify-untagged"
  build_notify_store "$untagged_store" '- channel: beeper-self'
  untagged_out="$("$VALIDATOR" "$untagged_store" 2>&1)"
  untagged_status=$?
  if [ "$untagged_status" -eq 1 ] && printf '%s' "$untagged_out" | grep -qi "Notify bullet"; then
    pass "validate-store.sh rejects an untagged Notify bullet"
  else
    fail "validate-store.sh gave exit $untagged_status (expected 1, with a Notify bullet complaint) for an untagged bullet"
    echo "$untagged_out"
  fi

  # --- assertion 12: unknown key -> error (exit 1) ---
  unknown_key_store="$TMP_ROOT/notify-unknown-key"
  build_notify_store "$unknown_key_store" '- **[stated-by-user]** sms_number: +15555550123 (2026-08-30)'
  unknown_key_out="$("$VALIDATOR" "$unknown_key_store" 2>&1)"
  unknown_key_status=$?
  if [ "$unknown_key_status" -eq 1 ] && printf '%s' "$unknown_key_out" | grep -qi "unknown key"; then
    pass "validate-store.sh rejects a Notify bullet with an unknown key"
  else
    fail "validate-store.sh gave exit $unknown_key_status (expected 1, with 'unknown key') for an unknown Notify key"
    echo "$unknown_key_out"
  fi
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
