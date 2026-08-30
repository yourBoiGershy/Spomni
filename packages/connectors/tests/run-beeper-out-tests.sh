#!/usr/bin/env bash
# packages/connectors/tests/run-beeper-out-tests.sh
#
# Offline test suite for the beeper-out send lane
# (packages/connectors/beeper-out/scripts/beeper-send.sh), per
# docs/plans/2026-08-30-33-nudge-delivery-beeper-self.md and
# packages/connectors/beeper-out/package.md. Proves the self-only invariant:
# the destination chat id is resolved solely from <store-dir>/profile.md's
# `## Notify` section, and zero HTTP calls happen on any refusal path.
#
# Covers:
#   1. Happy path: exactly one POST to /v1/chats/1/messages, body .text
#      equals the text file's contents (multi-line).
#   2. A chat id containing reserved characters (!abc:beeper.com) is
#      URL-encoded in the request path.
#   3. --chat-id mismatch against the profile -> exit 4, zero calls.
#   4. Profile with no ## Notify section -> exit 4, zero calls.
#   5. Missing beeper-in token -> exit 0, skip-no-token, zero calls.
#   6. Stub transport failure (non-2xx / curl-style error) -> exit 5,
#      send-failed.
#   7. --reminder posts a second request to /v1/chats/1/reminders with
#      .reminder.remindAt set.
#
# bash 3.2 portable (no associative arrays, no mapfile, no ${var,,}) — must
# run under macOS's stock /bin/bash. Same pass/fail/SUMMARY style as
# run-beeper-capture-tests.sh. Never edits the shipped script or lib.sh —
# only reads them, plus test-local mktemp fixtures created here.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SEND_SCRIPT="$REPO_ROOT/packages/connectors/beeper-out/scripts/beeper-send.sh"
FIXTURES_DIR="$REPO_ROOT/packages/connectors/beeper-out/fixtures"

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

# call_count <log-file> — number of recorded HTTP calls; 0 if the file was
# never created (the refusal/skip paths never write it).
call_count() {
  [ -f "$1" ] || { echo 0; return; }
  grep -c . "$1" 2>/dev/null
}

if [ ! -f "$SEND_SCRIPT" ]; then
  echo "SKIP: $SEND_SCRIPT not found — cannot run beeper-out tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, script missing"
  exit 1
fi

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "FAIL: fixtures dir missing at $FIXTURES_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

SANDBOX="$(mktemp -d)"
cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# make_root <name> [chat_id] [with_token] [with_notify] — builds a private
# data root at $SANDBOX/<name> with the `data/{store,connectors/beeper-in}`
# layout beeper-send.sh's default --private-data-root resolution expects
# (<store-dir>/../.. == the root). Prints the store dir on stdout.
# ---------------------------------------------------------------------------
make_root() {
  name="$1"
  chat_id="${2:-1}"
  with_token="${3:-1}"
  with_notify="${4:-1}"

  root="$SANDBOX/$name"
  store_dir="$root/data/store"
  beeper_in_dir="$root/data/connectors/beeper-in"
  mkdir -p "$store_dir" "$beeper_in_dir"

  cat > "$beeper_in_dir/config.json" <<EOF
{
  "base_url": "http://127.0.0.1:23373",
  "enabled_account_ids": ["matrix"]
}
EOF
  if [ "$with_token" = "1" ]; then
    printf 'test-token-abc\n' > "$beeper_in_dir/token"
  fi

  if [ "$with_notify" = "1" ]; then
    cat > "$store_dir/profile.md" <<EOF
---
schema_version: 1.1.0
---

## Priorities

## Cadence wishes

## Signal opt-outs

## Style notes

## Notify

- **[stated-by-user]** beeper_chat_id: ${chat_id} (2026-08-30)
EOF
  else
    cat > "$store_dir/profile.md" <<EOF
---
schema_version: 1.1.0
---

## Priorities

## Cadence wishes

## Signal opt-outs

## Style notes
EOF
  fi

  printf '%s\n' "$store_dir"
}

# --- recording stub: dispatches by path suffix, logs "METHOD PATH BODY" ---
# one line per call to $STUB_LOG, prints the matching fixture body.
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
  *)
    cat "$STUB_SEND_FIXTURE"
    ;;
esac
EOF
chmod +x "$recording_stub"

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

# =============================================================================
# 1. Happy path: exactly one POST to /v1/chats/1/messages, body .text equals
#    the (multi-line) text file's contents.
# =============================================================================

t1_store="$(make_root happy 1)"
t1_text="$SANDBOX/happy/nudge.txt"
printf 'Hey — checking in.\nLet me know if this week works.\n' > "$t1_text"
t1_log="$SANDBOX/happy/stub.log"

t1_out="$(
  export STUB_LOG="$t1_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t1_store" --text-file "$t1_text"
)"
t1_rc=$?

assert_eq "happy path: exit 0" "$t1_rc" "0"
assert_eq "happy path: prints sent chat=1" "$t1_out" "sent chat=1 message_id=msg-123"
assert_eq "happy path: exactly one HTTP call" "$(grep -c . "$t1_log" 2>/dev/null)" "1"
assert_eq "happy path: POST to /v1/chats/1/messages" "$(awk '{print $1, $2}' "$t1_log")" "POST /v1/chats/1/messages"

t1_body="$(sed 's/^POST \/v1\/chats\/1\/messages //' "$t1_log")"
t1_body_text="$(printf '%s' "$t1_body" | jq -r '.text')"
t1_file_contents="$(cat "$t1_text")"
assert_eq "happy path: body .text equals file contents (multi-line)" "$t1_body_text" "$t1_file_contents"

# =============================================================================
# 2. Chat id with reserved characters is URL-encoded in the request path.
# =============================================================================

t2_store="$(make_root encoded '!abc:beeper.com')"
t2_text="$SANDBOX/encoded/nudge.txt"
printf 'ping\n' > "$t2_text"
t2_log="$SANDBOX/encoded/stub.log"

(
  export STUB_LOG="$t2_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t2_store" --text-file "$t2_text"
) > /dev/null
t2_rc=$?

assert_eq "encoded chat id: exit 0" "$t2_rc" "0"
assert_eq "encoded chat id: path is percent-encoded" "$(awk '{print $2}' "$t2_log")" "/v1/chats/%21abc%3Abeeper.com/messages"

# =============================================================================
# 3. --chat-id mismatch against the profile -> exit 4, zero calls.
# =============================================================================

t3_store="$(make_root mismatch 1)"
t3_text="$SANDBOX/mismatch/nudge.txt"
printf 'ping\n' > "$t3_text"
t3_log="$SANDBOX/mismatch/stub.log"

t3_err="$( {
  export STUB_LOG="$t3_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t3_store" --text-file "$t3_text" --chat-id 2
} 2>&1 1>/dev/null )"
t3_rc=$?

assert_eq "chat-id mismatch: exit 4" "$t3_rc" "4"
assert_eq "chat-id mismatch: refuse message" "$t3_err" "refuse: chat id not in profile ## Notify"
assert_eq "chat-id mismatch: capture file empty" "$(call_count "$t3_log")" "0"

# =============================================================================
# 4. Profile without ## Notify -> exit 4, zero calls.
# =============================================================================

t4_store="$(make_root no-notify 1 1 0)"
t4_text="$SANDBOX/no-notify/nudge.txt"
printf 'ping\n' > "$t4_text"
t4_log="$SANDBOX/no-notify/stub.log"

t4_err="$( {
  export STUB_LOG="$t4_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t4_store" --text-file "$t4_text"
} 2>&1 1>/dev/null )"
t4_rc=$?

assert_eq "no ## Notify: exit 4" "$t4_rc" "4"
assert_eq "no ## Notify: refuse message" "$t4_err" "refuse: no beeper_chat_id in profile ## Notify"
assert_eq "no ## Notify: zero calls" "$(call_count "$t4_log")" "0"

# =============================================================================
# 5. Missing beeper-in token -> exit 0, skip-no-token, zero calls.
# =============================================================================

t5_store="$(make_root no-token 1 0)"
t5_text="$SANDBOX/no-token/nudge.txt"
printf 'ping\n' > "$t5_text"
t5_log="$SANDBOX/no-token/stub.log"

t5_out="$(
  export STUB_LOG="$t5_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t5_store" --text-file "$t5_text"
)"
t5_rc=$?

assert_eq "no token: exit 0" "$t5_rc" "0"
assert_eq "no token: prints skip-no-token" "$t5_out" "skip-no-token"
assert_eq "no token: zero calls" "$(call_count "$t5_log")" "0"

# =============================================================================
# 6. Stub returns a transport failure (non-2xx / curl-style error) ->
#    exit 5, send-failed.
# =============================================================================

t6_store="$(make_root transport-fail 1)"
t6_text="$SANDBOX/transport-fail/nudge.txt"
printf 'ping\n' > "$t6_text"
t6_log="$SANDBOX/transport-fail/stub.log"

t6_err="$( {
  export STUB_LOG="$t6_log"
  export STUB_FIXTURE="$FIXTURES_DIR/401.json"
  BEEPER_HTTP_STUB="$failing_stub" "$SEND_SCRIPT" "$t6_store" --text-file "$t6_text"
} 2>&1 1>/dev/null )"
t6_rc=$?

assert_eq "transport failure: exit 5" "$t6_rc" "5"
case "$t6_err" in
  send-failed*) pass "transport failure: stderr begins with send-failed" ;;
  *) fail "transport failure: stderr begins with send-failed (got [$t6_err])" ;;
esac
assert_eq "transport failure: exactly one call attempted" "$(grep -c . "$t6_log" 2>/dev/null)" "1"

# =============================================================================
# 7. --reminder posts a second request to /v1/chats/1/reminders with
#    .reminder.remindAt set.
# =============================================================================

t7_store="$(make_root reminder 1)"
t7_text="$SANDBOX/reminder/nudge.txt"
printf 'ping\n' > "$t7_text"
t7_log="$SANDBOX/reminder/stub.log"

t7_out="$(
  export STUB_LOG="$t7_log"
  export STUB_SEND_FIXTURE="$FIXTURES_DIR/send-ok.json"
  export STUB_REMINDER_FIXTURE="$FIXTURES_DIR/send-ok.json"
  BEEPER_HTTP_STUB="$recording_stub" "$SEND_SCRIPT" "$t7_store" --text-file "$t7_text" --reminder 2026-09-13T09:00:00Z
)"
t7_rc=$?

assert_eq "reminder: exit 0" "$t7_rc" "0"
assert_eq "reminder: two HTTP calls" "$(grep -c . "$t7_log" 2>/dev/null)" "2"
assert_eq "reminder: first call is the messages POST" "$(sed -n '1p' "$t7_log" | awk '{print $1, $2}')" "POST /v1/chats/1/messages"
assert_eq "reminder: second call is the reminders POST" "$(sed -n '2p' "$t7_log" | awk '{print $1, $2}')" "POST /v1/chats/1/reminders"

t7_reminder_body="$(sed -n '2p' "$t7_log" | sed 's/^POST \/v1\/chats\/1\/reminders //')"
t7_remind_at="$(printf '%s' "$t7_reminder_body" | jq -r '.reminder.remindAt')"
assert_eq "reminder: body .reminder.remindAt set" "$t7_remind_at" "2026-09-13T09:00:00Z"

# =============================================================================
# summary
# =============================================================================

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
