#!/usr/bin/env bash
# packages/connectors/tests/run-deliver-tests.sh
#
# Offline test suite for the delivery tick
# (packages/connectors/scripts/deliver-tick.sh) and the always-on outbox
# audit adapter (packages/connectors/file-out/scripts/file-out.sh), per
# docs/plans/2026-08-30-33-nudge-delivery-beeper-self.md.
#
# Mission test: proves idempotent, quiet-hours-respecting, self-only
# delivery — a fired wake-up batch is turned into exactly one delivered
# nudge, never redelivered, never sent inside the user's own quiet hours,
# and only ever addressed to the user's own self-chat/self-inbox.
#
# Covers:
#   1. First run: exactly one POST to /v1/chats/1/messages, outbox file
#      contains the renderer's own text (diffed against render-nudge-
#      cards.sh's direct output), delivered.log gets one beeper-self line.
#   2. Second run (same batch): "deliver: nothing new", zero POSTs,
#      delivered.log unchanged.
#   3. Quiet hours: --now 23:30 and 07:30 hold (no log line, zero POSTs);
#      --now 09:00 then sends.
#   4. No ## Notify section + beeper config present -> channel=beeper-self,
#      but no beeper_chat_id anywhere -> refuse -> outbox-only, zero POSTs.
#   5. No ## Notify + no beeper config -> gmail-self pending file exists,
#      no delivered.log line.
#   6. channel: outbox -> outbox line, zero POSTs.
#   7. channel: none -> none line, zero POSTs.
#   8. channel: beeper-self stated explicitly with no beeper_chat_id bullet
#      -> refuse -> outbox-only line, zero POSTs.
#   9. Empty-entries batch -> "deliver: empty batch <name>", delivered.log
#      gets a `none` line, no outbox file written for it.
#  10. Stub transport failure (exit 22) -> "deliver: send-failed", no log
#      line, deliver-tick exits 1; a later successful run then delivers it.
#  11. file-out.sh: two batches filed the same day produce two `## <batch>`
#      sections in the same outbox file.
#  12-15. Template comment guard, on-demand drafts (send/rerun/quiet-hours/
#      gmail-self).
#  16. Reminder (plan 33 D5b): a successful beeper-self batch send triggers
#      exactly one post-tick `--notify-reminder` call — no user reminder set
#      -> one /reminders POST; a user-set future reminder -> GET only, "
#      deliver: reminder kept (user)" logged, zero /reminders POSTs.
#
# bash 3.2 portable (no associative arrays, no mapfile, no ${var,,}). Never
# edits the shipped scripts — only reads them, plus test-local sandbox
# fixtures created here. Fully offline: BEEPER_HTTP_STUB intercepts every
# HTTP call beeper-send.sh would otherwise make via curl.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DELIVER_SCRIPT="$REPO_ROOT/packages/connectors/scripts/deliver-tick.sh"
FILE_OUT_SCRIPT="$REPO_ROOT/packages/connectors/file-out/scripts/file-out.sh"
RENDER_SCRIPT="$REPO_ROOT/packages/core/scripts/render-nudge-cards.sh"
FIXTURE_BATCH="$REPO_ROOT/packages/core/fixtures/fired-batch/batch.json"
BEEPER_OUT_FIXTURES="$REPO_ROOT/packages/connectors/beeper-out/fixtures"
PROFILE_TEMPLATE="$REPO_ROOT/packages/core/templates/profile.md"

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

assert_eq() {
  # $1=description $2=actual $3=expected
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected [$3], got [$2])"
  fi
}

assert_contains() {
  # $1=description $2=haystack $3=needle
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1 (expected to find [$3] in [$2])" ;;
  esac
}

call_count() {
  [ -f "$1" ] || { echo 0; return; }
  grep -c . "$1" 2>/dev/null
}

for f in "$DELIVER_SCRIPT" "$FILE_OUT_SCRIPT" "$RENDER_SCRIPT" "$FIXTURE_BATCH" "$PROFILE_TEMPLATE"; do
  if [ ! -f "$f" ]; then
    echo "SKIP: $f not found — cannot run deliver tests yet."
    echo ""
    echo "SUMMARY: 0 passed, 0 failed, script missing"
    exit 1
  fi
done

SANDBOX="$(mktemp -d)"
cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# make_store <name> — builds a private data root at $SANDBOX/<name> with the
# data/store layout deliver-tick.sh's default --private-data-root
# resolution expects. Prints the store dir on stdout.
# ---------------------------------------------------------------------------
make_store() {
  name="$1"
  root="$SANDBOX/$name"
  store_dir="$root/data/store"
  mkdir -p "$store_dir/wakeups/fired"
  printf '%s\n' "$store_dir"
}

# ---------------------------------------------------------------------------
# enable_beeper <root> [with_token] — adds data/connectors/beeper-in's
# config.json (+ token, unless with_token=0) to the given private data root.
# ---------------------------------------------------------------------------
enable_beeper() {
  root="$1"
  with_token="${2:-1}"
  beeper_in_dir="$root/data/connectors/beeper-in"
  mkdir -p "$beeper_in_dir"
  cat > "$beeper_in_dir/config.json" <<EOF
{
  "base_url": "http://127.0.0.1:23373",
  "enabled_account_ids": ["matrix"]
}
EOF
  if [ "$with_token" = "1" ]; then
    printf 'test-token-abc\n' > "$beeper_in_dir/token"
  fi
}

# ---------------------------------------------------------------------------
# write_profile <store> [notify-body] — writes profile.md with the fixed
# sections plus an optional ## Notify section (notify-body = the bullet
# lines under it). Omit the second arg for no ## Notify section at all.
# ---------------------------------------------------------------------------
write_profile() {
  store="$1"
  notify_body="${2:-}"
  {
    printf -- '---\nschema_version: 1.1.0\n---\n\n'
    printf '## Priorities\n\n## Cadence wishes\n\n## Signal opt-outs\n\n## Style notes\n'
    if [ -n "$notify_body" ]; then
      printf '\n## Notify\n\n%s\n' "$notify_body"
    fi
  } > "$store/profile.md"
}

# ---------------------------------------------------------------------------
# place_batch <store> <batch-basename> [entries-empty] — copies the shared
# fixture batch (or an empty-entries variant) into wakeups/fired/ under the
# given basename (must end in -batch.json for deliver-tick.sh to see it).
# ---------------------------------------------------------------------------
place_batch() {
  store="$1"
  basename="$2"
  empty="${3:-0}"
  dest="$store/wakeups/fired/${basename}"
  if [ "$empty" = "1" ]; then
    jq '.entries = []' "$FIXTURE_BATCH" > "$dest"
  else
    cp "$FIXTURE_BATCH" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# place_draft <store> <draft-basename> [text] — writes an on-demand draft
# file (plan 34 feedback-parse.sh's output shape) into outbox/drafts/.
# ---------------------------------------------------------------------------
place_draft() {
  store="$1"
  basename="$2"
  text="${3:-hey, want to grab coffee this week?}"
  mkdir -p "$store/outbox/drafts"
  printf 'Draft (unsent):\n%s\n' "$text" > "$store/outbox/drafts/${basename}"
}

# --- recording stub: dispatches by path suffix, logs "METHOD PATH BODY" ---
recording_stub="$SANDBOX/recording-stub.sh"
cat > "$recording_stub" <<'EOF'
#!/bin/sh
method="$1"
path="$2"
body="$3"
[ -n "${STUB_LOG:-}" ] && printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_LOG"
case "$path" in
  */reminders)
    cat "$STUB_REMINDER_FIXTURE"
    ;;
  */messages)
    cat "$STUB_SEND_FIXTURE"
    ;;
  *)
    cat "$STUB_CHAT_FIXTURE"
    ;;
esac
EOF
chmod +x "$recording_stub"

# messages_post_count/reminders_post_count <log> — number of calls whose
# path targets /messages or /reminders respectively (deliver-tick's own
# beeper-self send vs. the post-tick --notify-reminder call, distinguished
# from the reminder-check GET which also hits the log).
messages_post_count() {
  [ -f "$1" ] || { echo 0; return; }
  awk '$1 == "POST" && $2 ~ /\/messages$/' "$1" | wc -l | tr -d ' '
}
reminders_post_count() {
  [ -f "$1" ] || { echo 0; return; }
  awk '$1 == "POST" && $2 ~ /\/reminders$/' "$1" | wc -l | tr -d ' '
}

# --- failing stub: logs the call, prints an error body, exits non-zero
# (curl-style transport failure). ---
failing_stub="$SANDBOX/failing-stub.sh"
cat > "$failing_stub" <<'EOF'
#!/bin/sh
method="$1"
path="$2"
body="$3"
[ -n "${STUB_LOG:-}" ] && printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_LOG"
cat "$STUB_FIXTURE"
exit 22
EOF
chmod +x "$failing_stub"

# ---------------------------------------------------------------------------
# outbox_section_matches_render <store> <batch-file> <outbox-file> —
# extracts the batch's section body from the outbox file (between the
# "## <name>" header + blank line and file-out.sh's trailing blank line)
# and diffs it against render-nudge-cards.sh's own direct output. Prints
# "match" or "diff: <output>".
# ---------------------------------------------------------------------------
outbox_section_matches_render() {
  batch_file="$1"
  outbox_file="$2"
  render_tmp="$(mktemp)"
  "$RENDER_SCRIPT" "$batch_file" > "$render_tmp" 2>/dev/null
  body_lines="$(wc -l < "$render_tmp" | tr -d ' ')"
  extracted_tmp="$(mktemp)"
  sed -n "3,$((2 + body_lines))p" "$outbox_file" > "$extracted_tmp"
  if diff -q "$render_tmp" "$extracted_tmp" >/dev/null 2>&1; then
    echo "match"
  else
    echo "diff: $(diff "$render_tmp" "$extracted_tmp")"
  fi
  rm -f "$render_tmp" "$extracted_tmp"
}

# =============================================================================
# 1. First run: exactly one POST, outbox contains renderer's text, delivered
#    log gets one beeper-self line.
# =============================================================================

t1_store="$(make_store t1)"
t1_root="$(cd "$t1_store/../.." && pwd)"
enable_beeper "$t1_root"
write_profile "$t1_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
- **[stated-by-user]** quiet_hours: 22:00-08:00 (2026-08-30)"
place_batch "$t1_store" "2026-08-30T130000Z-batch.json"
t1_log="$SANDBOX/t1/stub.log"
mkdir -p "$SANDBOX/t1"

t1_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t1_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t1_store" --today 2026-08-30 --now 09:00
)"
t1_rc=$?

assert_eq "first run: exit 0" "$t1_rc" "0"
assert_contains "first run: channel=beeper-self printed" "$t1_out" "deliver: channel=beeper-self"
assert_contains "first run: summary sent=1" "$t1_out" "deliver: done sent=1 outbox=0 pending=0 held=0"
assert_eq "first run: one messages POST" "$(messages_post_count "$t1_log")" "1"
assert_eq "first run: exactly one /reminders POST" "$(reminders_post_count "$t1_log")" "1"
assert_eq "first run: POST to /v1/chats/1/messages" "$(awk '$1=="POST" && $2 ~ /\/messages$/ {print $1, $2}' "$t1_log")" "POST /v1/chats/1/messages"
assert_contains "first run: reminder line logged" "$t1_out" "deliver: reminder set at="

t1_delivered="$t1_store/outbox/delivered.log"
assert_eq "first run: delivered.log has one line" "$(call_count "$t1_delivered")" "1"
assert_eq "first run: delivered.log line is beeper-self" "$(awk -F'\t' '{print $2}' "$t1_delivered")" "beeper-self"

t1_outbox="$t1_store/outbox/2026-08-30.md"
if [ -f "$t1_outbox" ]; then
  t1_match="$(outbox_section_matches_render "$t1_store/wakeups/fired/2026-08-30T130000Z-batch.json" "$t1_outbox")"
  assert_eq "first run: outbox body matches render-nudge-cards.sh output" "$t1_match" "match"
else
  fail "first run: outbox file exists at $t1_outbox"
fi

# =============================================================================
# 2. Second run (same batch, same store): nothing new, zero POSTs, log
#    unchanged.
# =============================================================================

t1_delivered_before="$(cat "$t1_delivered")"
t2_log="$SANDBOX/t1/stub2.log"

t2_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t2_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t1_store" --today 2026-08-30 --now 09:00
)"
t2_rc=$?

assert_eq "second run: exit 0" "$t2_rc" "0"
assert_eq "second run: nothing new" "$t2_out" "deliver: nothing new"
assert_eq "second run: zero POSTs" "$(call_count "$t2_log")" "0"
assert_eq "second run: delivered.log unchanged" "$(cat "$t1_delivered")" "$t1_delivered_before"

# =============================================================================
# 3. Quiet hours: 23:30 and 07:30 hold; 09:00 then sends.
# =============================================================================

t3_store="$(make_store t3)"
t3_root="$(cd "$t3_store/../.." && pwd)"
enable_beeper "$t3_root"
write_profile "$t3_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
- **[stated-by-user]** quiet_hours: 22:00-08:00 (2026-08-30)"
place_batch "$t3_store" "2026-08-30T130000Z-batch.json"
t3_delivered="$t3_store/outbox/delivered.log"

t3a_log="$SANDBOX/t3/stub-a.log"
mkdir -p "$SANDBOX/t3"
t3a_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t3a_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t3_store" --today 2026-08-30 --now 23:30
)"
assert_contains "quiet hours 23:30: hold line" "$t3a_out" "deliver: quiet-hours hold n=1"
assert_eq "quiet hours 23:30: zero POSTs" "$(call_count "$t3a_log")" "0"
assert_eq "quiet hours 23:30: no delivered.log written" "$(call_count "$t3_delivered")" "0"

t3b_log="$SANDBOX/t3/stub-b.log"
t3b_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t3b_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t3_store" --today 2026-08-30 --now 07:30
)"
assert_contains "quiet hours 07:30: hold line" "$t3b_out" "deliver: quiet-hours hold n=1"
assert_eq "quiet hours 07:30: zero POSTs" "$(call_count "$t3b_log")" "0"
assert_eq "quiet hours 07:30: no delivered.log written" "$(call_count "$t3_delivered")" "0"

t3c_log="$SANDBOX/t3/stub-c.log"
t3c_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t3c_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t3_store" --today 2026-08-30 --now 09:00
)"
assert_contains "09:00: sends (not held)" "$t3c_out" "deliver: done sent=1 outbox=0 pending=0 held=0"
assert_eq "09:00: one messages POST" "$(messages_post_count "$t3c_log")" "1"
assert_eq "09:00: one reminders POST" "$(reminders_post_count "$t3c_log")" "1"
assert_eq "09:00: delivered.log has one line" "$(call_count "$t3_delivered")" "1"

# =============================================================================
# 4. No ## Notify section + beeper config present -> channel=beeper-self,
#    but no beeper_chat_id anywhere -> refuse -> outbox-only, zero POSTs.
# =============================================================================

t4_store="$(make_store t4)"
t4_root="$(cd "$t4_store/../.." && pwd)"
enable_beeper "$t4_root"
write_profile "$t4_store"
place_batch "$t4_store" "2026-08-30T130000Z-batch.json"
t4_log="$SANDBOX/t4/stub.log"
mkdir -p "$SANDBOX/t4"

t4_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t4_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t4_store" --today 2026-08-30 --now 09:00
)"

assert_contains "no ## Notify + beeper config: channel=beeper-self" "$t4_out" "deliver: channel=beeper-self"
assert_contains "no ## Notify + beeper config: refuse line" "$t4_out" "refuse: no beeper_chat_id in profile ## Notify"
assert_eq "no ## Notify + beeper config: zero POSTs" "$(call_count "$t4_log")" "0"
t4_delivered="$t4_store/outbox/delivered.log"
assert_eq "no ## Notify + beeper config: delivered.log line is outbox" "$(awk -F'\t' '{print $2}' "$t4_delivered")" "outbox"

# =============================================================================
# 5. No ## Notify + no beeper config -> gmail-self pending file exists, no
#    delivered.log line.
# =============================================================================

t5_store="$(make_store t5)"
write_profile "$t5_store"
place_batch "$t5_store" "2026-08-30T130000Z-batch.json"

t5_out="$(
  "$DELIVER_SCRIPT" "$t5_store" --today 2026-08-30 --now 09:00
)"

assert_contains "no ## Notify + no beeper config: channel=gmail-self" "$t5_out" "deliver: channel=gmail-self"
assert_contains "no ## Notify + no beeper config: pending line" "$t5_out" "deliver: gmail-self pending (session) 2026-08-30T130000Z-batch.json"
assert_eq "no ## Notify + no beeper config: pending file exists" "$([ -f "$t5_store/outbox/pending-gmail/2026-08-30T130000Z-batch.json.txt" ] && echo yes || echo no)" "yes"
t5_delivered="$t5_store/outbox/delivered.log"
assert_eq "no ## Notify + no beeper config: no delivered.log line" "$(call_count "$t5_delivered")" "0"

# =============================================================================
# 6. channel: outbox -> outbox line, zero POSTs.
# =============================================================================

t6_store="$(make_store t6)"
write_profile "$t6_store" "- **[stated-by-user]** channel: outbox (2026-08-30)"
place_batch "$t6_store" "2026-08-30T130000Z-batch.json"
t6_log="$SANDBOX/t6/stub.log"
mkdir -p "$SANDBOX/t6"

t6_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t6_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t6_store" --today 2026-08-30 --now 09:00
)"

assert_contains "channel: outbox: channel line" "$t6_out" "deliver: channel=outbox"
assert_eq "channel: outbox: zero POSTs" "$(call_count "$t6_log")" "0"
t6_delivered="$t6_store/outbox/delivered.log"
assert_eq "channel: outbox: delivered.log line is outbox" "$(awk -F'\t' '{print $2}' "$t6_delivered")" "outbox"

# =============================================================================
# 7. channel: none -> none line, zero POSTs.
# =============================================================================

t7_store="$(make_store t7)"
write_profile "$t7_store" "- **[stated-by-user]** channel: none (2026-08-30)"
place_batch "$t7_store" "2026-08-30T130000Z-batch.json"
t7_log="$SANDBOX/t7/stub.log"
mkdir -p "$SANDBOX/t7"

t7_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t7_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t7_store" --today 2026-08-30 --now 09:00
)"

assert_contains "channel: none: channel line" "$t7_out" "deliver: channel=none"
assert_eq "channel: none: zero POSTs" "$(call_count "$t7_log")" "0"
t7_delivered="$t7_store/outbox/delivered.log"
assert_eq "channel: none: delivered.log line is none" "$(awk -F'\t' '{print $2}' "$t7_delivered")" "none"

# =============================================================================
# 8. channel: beeper-self stated explicitly with no beeper_chat_id bullet
#    -> refuse -> outbox-only line, zero POSTs.
# =============================================================================

t8_store="$(make_store t8)"
t8_root="$(cd "$t8_store/../.." && pwd)"
enable_beeper "$t8_root"
write_profile "$t8_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)"
place_batch "$t8_store" "2026-08-30T130000Z-batch.json"
t8_log="$SANDBOX/t8/stub.log"
mkdir -p "$SANDBOX/t8"

t8_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t8_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t8_store" --today 2026-08-30 --now 09:00
)"

assert_contains "beeper-self no chat id: refuse line" "$t8_out" "refuse: no beeper_chat_id in profile ## Notify"
assert_eq "beeper-self no chat id: zero POSTs" "$(call_count "$t8_log")" "0"
t8_delivered="$t8_store/outbox/delivered.log"
assert_eq "beeper-self no chat id: delivered.log line is outbox" "$(awk -F'\t' '{print $2}' "$t8_delivered")" "outbox"

# =============================================================================
# 9. Empty-entries batch -> "deliver: empty batch <name>", delivered.log
#    gets a `none` line, no outbox file written for it.
# =============================================================================

t9_store="$(make_store t9)"
write_profile "$t9_store" "- **[stated-by-user]** channel: none (2026-08-30)"
place_batch "$t9_store" "2026-08-30T130000Z-batch.json" 1

t9_out="$(
  "$DELIVER_SCRIPT" "$t9_store" --today 2026-08-30 --now 09:00
)"

assert_contains "empty batch: empty batch line" "$t9_out" "deliver: empty batch 2026-08-30T130000Z-batch.json"
t9_delivered="$t9_store/outbox/delivered.log"
assert_eq "empty batch: delivered.log line is none" "$(awk -F'\t' '{print $2}' "$t9_delivered")" "none"
assert_eq "empty batch: no outbox .md file written" "$([ -f "$t9_store/outbox/2026-08-30.md" ] && echo yes || echo no)" "no"

# =============================================================================
# 10. Stub transport failure (exit 22) -> send-failed, no log line, exit 1;
#     a later successful run then delivers it.
# =============================================================================

t10_store="$(make_store t10)"
t10_root="$(cd "$t10_store/../.." && pwd)"
enable_beeper "$t10_root"
write_profile "$t10_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)"
place_batch "$t10_store" "2026-08-30T130000Z-batch.json"
t10_delivered="$t10_store/outbox/delivered.log"
mkdir -p "$SANDBOX/t10"

t10a_log="$SANDBOX/t10/stub-a.log"
t10a_out="$(
  export BEEPER_HTTP_STUB="$failing_stub"
  export STUB_LOG="$t10a_log"
  export STUB_FIXTURE="$BEEPER_OUT_FIXTURES/401.json"
  "$DELIVER_SCRIPT" "$t10_store" --today 2026-08-30 --now 09:00
)"
t10a_rc=$?

assert_contains "send-failed: send-failed line" "$t10a_out" "deliver: send-failed 2026-08-30T130000Z-batch.json"
assert_eq "send-failed: exit 1" "$t10a_rc" "1"
assert_eq "send-failed: no delivered.log line" "$(call_count "$t10_delivered")" "0"

t10b_log="$SANDBOX/t10/stub-b.log"
t10b_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t10b_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t10_store" --today 2026-08-30 --now 09:00
)"
t10b_rc=$?

assert_eq "send-failed retry: exit 0" "$t10b_rc" "0"
assert_contains "send-failed retry: sends" "$t10b_out" "deliver: done sent=1 outbox=0 pending=0 held=0"
assert_eq "send-failed retry: one messages POST" "$(messages_post_count "$t10b_log")" "1"
assert_eq "send-failed retry: one reminders POST" "$(reminders_post_count "$t10b_log")" "1"
assert_eq "send-failed retry: delivered.log now has one line" "$(call_count "$t10_delivered")" "1"

# =============================================================================
# 11. file-out.sh: two batches filed the same day produce two ## <batch>
#     sections in the same outbox file.
# =============================================================================

t11_store="$(make_store t11)"
t11_text_a="$SANDBOX/t11/a.txt"
t11_text_b="$SANDBOX/t11/b.txt"
mkdir -p "$SANDBOX/t11"
printf 'card A text\n' > "$t11_text_a"
printf 'card B text\n' > "$t11_text_b"

"$FILE_OUT_SCRIPT" "$t11_store" --text-file "$t11_text_a" --batch "batch-a-batch.json" --today 2026-08-30 > /dev/null
"$FILE_OUT_SCRIPT" "$t11_store" --text-file "$t11_text_b" --batch "batch-b-batch.json" --today 2026-08-30 > /dev/null

t11_outbox="$t11_store/outbox/2026-08-30.md"
assert_eq "file-out: two ## sections in one outbox file" "$(grep -c '^## ' "$t11_outbox")" "2"
assert_contains "file-out: section a header present" "$(cat "$t11_outbox")" "## batch-a-batch.json"
assert_contains "file-out: section b header present" "$(cat "$t11_outbox")" "## batch-b-batch.json"

# =============================================================================
# 12. Template comment lines must never satisfy notify_get: build profile.md
#     from the template verbatim (its ## Notify comments include a literal
#     "beeper_chat_id: <id> (<YYYY-MM-DD>)" line) plus real bullets appended
#     underneath. Must resolve channel=beeper-self / chat 1, exactly one POST
#     to /v1/chats/1/messages.
# =============================================================================

t12_store="$(make_store t12)"
t12_root="$(cd "$t12_store/../.." && pwd)"
enable_beeper "$t12_root"
cp "$PROFILE_TEMPLATE" "$t12_store/profile.md"
cat >> "$t12_store/profile.md" <<'EOF'
- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
EOF
place_batch "$t12_store" "2026-08-30T130000Z-batch.json"
t12_log="$SANDBOX/t12/stub.log"
mkdir -p "$SANDBOX/t12"

t12_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t12_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t12_store" --today 2026-08-30 --now 09:00
)"

assert_contains "template comment guard: channel=beeper-self" "$t12_out" "deliver: channel=beeper-self"
assert_eq "template comment guard: one messages POST" "$(messages_post_count "$t12_log")" "1"
assert_eq "template comment guard: one reminders POST" "$(reminders_post_count "$t12_log")" "1"
assert_eq "template comment guard: POST to /v1/chats/1/messages" "$(awk '$1=="POST" && $2 ~ /\/messages$/ {print $1, $2}' "$t12_log")" "POST /v1/chats/1/messages"

# =============================================================================
# 13. Draft file + beeper-self: one POST whose body starts with
#     "Draft (unsent):", delivered.log gets a draft:beeper-self line, outbox
#     file contains it. Rerun: nothing new, zero POSTs, log unchanged.
# =============================================================================

t13_store="$(make_store t13)"
t13_root="$(cd "$t13_store/../.." && pwd)"
enable_beeper "$t13_root"
write_profile "$t13_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)"
place_draft "$t13_store" "2026-08-30T130000Z-batch.json-1-draft.txt"
t13_log="$SANDBOX/t13/stub.log"
mkdir -p "$SANDBOX/t13"

t13_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t13_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t13_store" --today 2026-08-30 --now 09:00
)"
t13_rc=$?

assert_eq "draft first run: exit 0" "$t13_rc" "0"
assert_contains "draft first run: draft sent line" "$t13_out" "deliver: draft sent 2026-08-30T130000Z-batch.json-1-draft.txt"
assert_contains "draft first run: summary drafts=1" "$t13_out" "drafts=1"
assert_eq "draft first run: one messages POST" "$(messages_post_count "$t13_log")" "1"
assert_eq "draft first run: one reminders POST" "$(reminders_post_count "$t13_log")" "1"
t13_json="$(grep '^POST /v1/chats/1/messages ' "$t13_log" | sed -e 's|^POST /v1/chats/1/messages ||')"
t13_text="$(printf '%s' "$t13_json" | jq -r '.text')"
case "$t13_text" in
  "Draft (unsent):"*) pass "draft first run: POST body .text starts with Draft (unsent):" ;;
  *) fail "draft first run: POST body .text starts with Draft (unsent): (got [$t13_text])" ;;
esac

t13_delivered="$t13_store/outbox/delivered.log"
assert_eq "draft first run: delivered.log has one line" "$(call_count "$t13_delivered")" "1"
assert_eq "draft first run: delivered.log line is draft:beeper-self" "$(awk -F'\t' '{print $2}' "$t13_delivered")" "draft:beeper-self"

t13_outbox="$t13_store/outbox/2026-08-30.md"
assert_eq "draft first run: outbox file has draft section" "$([ -f "$t13_outbox" ] && grep -q '^## 2026-08-30T130000Z-batch.json-1-draft.txt$' "$t13_outbox" && echo yes || echo no)" "yes"
assert_contains "draft first run: outbox body contains Draft (unsent):" "$(cat "$t13_outbox")" "Draft (unsent):"

t13_delivered_before="$(cat "$t13_delivered")"
t13b_log="$SANDBOX/t13/stub-b.log"
t13b_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t13b_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t13_store" --today 2026-08-30 --now 09:00
)"
assert_eq "draft rerun: nothing new" "$t13b_out" "deliver: nothing new"
assert_eq "draft rerun: zero POSTs" "$(call_count "$t13b_log")" "0"
assert_eq "draft rerun: delivered.log unchanged" "$(cat "$t13_delivered")" "$t13_delivered_before"

# =============================================================================
# 14. Quiet hours hold applies to drafts too (no batches present).
# =============================================================================

t14_store="$(make_store t14)"
t14_root="$(cd "$t14_store/../.." && pwd)"
enable_beeper "$t14_root"
write_profile "$t14_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
- **[stated-by-user]** quiet_hours: 22:00-08:00 (2026-08-30)"
place_draft "$t14_store" "2026-08-30T130000Z-batch.json-1-draft.txt"
t14_delivered="$t14_store/outbox/delivered.log"
t14_log="$SANDBOX/t14/stub.log"
mkdir -p "$SANDBOX/t14"

t14_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t14_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t14_store" --today 2026-08-30 --now 23:30
)"
assert_contains "draft quiet hours: hold line" "$t14_out" "deliver: quiet-hours hold n=1"
assert_eq "draft quiet hours: zero POSTs" "$(call_count "$t14_log")" "0"
assert_eq "draft quiet hours: no delivered.log written" "$(call_count "$t14_delivered")" "0"

t14b_log="$SANDBOX/t14/stub-b.log"
t14b_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t14b_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-null.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t14_store" --today 2026-08-30 --now 09:00
)"
assert_contains "draft quiet hours: 09:00 sends" "$t14b_out" "drafts=1"
assert_eq "draft quiet hours: 09:00 one messages POST" "$(messages_post_count "$t14b_log")" "1"
assert_eq "draft quiet hours: 09:00 one reminders POST" "$(reminders_post_count "$t14b_log")" "1"

# =============================================================================
# 15. Draft file + gmail-self: pending file exists, no delivered.log line.
# =============================================================================

t15_store="$(make_store t15)"
write_profile "$t15_store"
place_draft "$t15_store" "2026-08-30T130000Z-batch.json-1-draft.txt"

t15_out="$(
  "$DELIVER_SCRIPT" "$t15_store" --today 2026-08-30 --now 09:00
)"

assert_contains "draft gmail-self: pending line" "$t15_out" "deliver: draft pending (session) 2026-08-30T130000Z-batch.json-1-draft.txt"
assert_eq "draft gmail-self: pending file exists" "$([ -f "$t15_store/outbox/pending-gmail/2026-08-30T130000Z-batch.json-1-draft.txt.txt" ] && echo yes || echo no)" "yes"
t15_delivered="$t15_store/outbox/delivered.log"
assert_eq "draft gmail-self: no delivered.log line" "$(call_count "$t15_delivered")" "0"

# =============================================================================
# 16. Reminder kept (user): the chat already has a user-set future reminder
#     (plan 33 D5b) -> after a successful batch send, the GET fires but no
#     /reminders POST does; log line "deliver: reminder kept (user) at=...".
# =============================================================================

t16_store="$(make_store t16)"
t16_root="$(cd "$t16_store/../.." && pwd)"
enable_beeper "$t16_root"
write_profile "$t16_store" "- **[stated-by-user]** channel: beeper-self (2026-08-30)
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)"
place_batch "$t16_store" "2026-08-30T130000Z-batch.json"
t16_log="$SANDBOX/t16/stub.log"
mkdir -p "$SANDBOX/t16"

t16_out="$(
  export BEEPER_HTTP_STUB="$recording_stub"
  export STUB_LOG="$t16_log"
  export STUB_SEND_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  export STUB_CHAT_FIXTURE="$BEEPER_OUT_FIXTURES/chat-reminder-future.json"
  export STUB_REMINDER_FIXTURE="$BEEPER_OUT_FIXTURES/send-ok.json"
  "$DELIVER_SCRIPT" "$t16_store" --today 2026-08-30 --now 09:00
)"
t16_rc=$?

assert_eq "reminder kept: exit 0" "$t16_rc" "0"
assert_contains "reminder kept: summary sent=1" "$t16_out" "deliver: done sent=1 outbox=0 pending=0 held=0"
assert_eq "reminder kept: one messages POST" "$(messages_post_count "$t16_log")" "1"
assert_eq "reminder kept: zero reminders POST" "$(reminders_post_count "$t16_log")" "0"
assert_contains "reminder kept: log line" "$t16_out" "deliver: reminder kept (user) at=2026-09-03T13:00:00.000Z"

# =============================================================================
# summary
# =============================================================================

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
