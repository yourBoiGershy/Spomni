#!/usr/bin/env bash
# packages/connectors/tests/run-beeper-capture-tests.sh
#
# Offline test suite for the beeper-in shared library
# (packages/connectors/beeper-in/scripts/lib.sh), per
# docs/plans/2026-08-29-13-beeper-capture.md ("Runtime state", "Failure
# posture", "Read-only enforcement"). Covers:
#
#   1. beeper_load_config: valid config+token, missing config.json,
#      empty enabled_account_ids, missing token — return-code contract
#      (0 = loaded, 2 = skip-disabled, 3 = skip-no-token).
#   2. cursors.tsv: set/get round-trip, re-set overwrites (no dup lines),
#      unknown chat, URL-ish characters survive.
#   3. beeper_get stub injection: BEEPER_HTTP_STUB is used instead of curl
#      (asserted by recording argv and by a fake curl that would leave a
#      sentinel file if ever invoked).
#   4. Status lines: run_log's documented format; the EXIT trap writes
#      `error` when a script exits without logging, and does NOT clobber
#      a script that already logged `ok`.
#   5. Read-only grep guard: no -X / --data / -d in executable (non-comment)
#      lines of the shipped scripts, exactly one curl call site, and no
#      state-changing paths (/read, /archive, /reminders) anywhere.
#   6. Pagination helpers against the stub + fixtures: fetch_new_messages
#      (no-cursor single GET; cursor+hasMore loop with direction=after) and
#      list_new_chats (repeated accountIDs= params).
#   7. End-to-end: beeper-sweep.sh itself, run against the HTTP stub +
#      fixtures into a real mktemp store via the real normalize-capture.sh —
#      full run (inbox events + hints + runs.log), cursor dedup on a second
#      run, skip-unreachable, skip-disabled, and the normalizer-quarantine
#      partial-run path (cursor left unadvanced for the quarantined chat
#      only).
#
# bash 3.2 portable (no associative arrays, no mapfile, no ${var,,}) — must
# run under macOS's stock /bin/bash. Same pass/fail/SUMMARY style as
# run-capture-tests.sh. Never edits lib.sh, fixtures/, or any shipped
# script — only reads them, plus test-local mktemp fixtures created here.
#
# --- E2E tests appended by unit S5 below ---
# (that marker also appears again, verbatim, at the end of this file —
# S5 extends this suite in place rather than creating a second file.)

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LIB="$REPO_ROOT/packages/connectors/beeper-in/scripts/lib.sh"
SCRIPTS_DIR="$REPO_ROOT/packages/connectors/beeper-in/scripts"
FIXTURES_DIR="$REPO_ROOT/packages/connectors/beeper-in/fixtures"

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

# field <blob> <key> — pull KEY=VALUE out of a multi-line blob produced by
# the run_* helpers below (one KEY=VALUE per line).
field() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

if [ ! -f "$LIB" ]; then
  echo "SKIP: $LIB not found — cannot run beeper lib tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, lib.sh missing"
  exit 1
fi

if [ ! -d "$FIXTURES_DIR" ]; then
  echo "FAIL: fixtures dir missing at $FIXTURES_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# shellcheck disable=SC1090
source "$LIB"

# --- throwaway sandbox, cleaned up on exit ---
SANDBOX="$(mktemp -d)"
cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# =============================================================================
# 1. beeper_load_config — config/skip states
# =============================================================================

run_load_config() {
  # $1 = data_dir; prints RC=<n> then KEY=VALUE lines when rc=0
  (
    beeper_load_config "$1"
    rc=$?
    echo "RC=$rc"
    if [ "$rc" -eq 0 ]; then
      echo "BASE_URL=$BASE_URL"
      echo "STORE_DIR=$STORE_DIR"
      echo "MAX_CHATS_PER_RUN=$MAX_CHATS_PER_RUN"
      echo "MAX_PAGES_PER_CHAT=$MAX_PAGES_PER_CHAT"
      echo "BEEPER_TOKEN=$BEEPER_TOKEN"
      echo "IDS_COUNT=$(printf '%s\n' "$ENABLED_ACCOUNT_IDS" | grep -c .)"
      echo "IDS_HAS_MATRIX=$(printf '%s\n' "$ENABLED_ACCOUNT_IDS" | grep -c '^matrix$')"
    fi
  )
}

cfg_valid="$SANDBOX/cfg-valid"
mkdir -p "$cfg_valid"
cat > "$cfg_valid/config.json" <<'EOF'
{
  "base_url": "http://127.0.0.1:23373",
  "store_dir": "data/store",
  "enabled_account_ids": ["matrix", "local-whatsapp_ba_test1"],
  "max_chats_per_run": 7,
  "max_pages_per_chat": 3
}
EOF
printf 'test-token-abc\n' > "$cfg_valid/token"

out_valid="$(run_load_config "$cfg_valid")"
assert_eq "load_config: valid config+token returns rc=0" "$(field "$out_valid" RC)" "0"
assert_eq "load_config: BASE_URL parsed" "$(field "$out_valid" BASE_URL)" "http://127.0.0.1:23373"
assert_eq "load_config: STORE_DIR parsed" "$(field "$out_valid" STORE_DIR)" "data/store"
assert_eq "load_config: MAX_CHATS_PER_RUN parsed" "$(field "$out_valid" MAX_CHATS_PER_RUN)" "7"
assert_eq "load_config: MAX_PAGES_PER_CHAT parsed" "$(field "$out_valid" MAX_PAGES_PER_CHAT)" "3"
assert_eq "load_config: BEEPER_TOKEN parsed" "$(field "$out_valid" BEEPER_TOKEN)" "test-token-abc"
assert_eq "load_config: enabled_account_ids count=2" "$(field "$out_valid" IDS_COUNT)" "2"
assert_eq "load_config: enabled_account_ids includes matrix" "$(field "$out_valid" IDS_HAS_MATRIX)" "1"

cfg_missing="$SANDBOX/cfg-missing"
mkdir -p "$cfg_missing"
out_missing="$(run_load_config "$cfg_missing")"
assert_eq "load_config: missing config.json returns rc=2" "$(field "$out_missing" RC)" "2"

cfg_empty_ids="$SANDBOX/cfg-empty-ids"
mkdir -p "$cfg_empty_ids"
cat > "$cfg_empty_ids/config.json" <<'EOF'
{"base_url":"http://127.0.0.1:23373","store_dir":"data/store","enabled_account_ids":[],"max_chats_per_run":50,"max_pages_per_chat":20}
EOF
printf 'tok\n' > "$cfg_empty_ids/token"
out_empty_ids="$(run_load_config "$cfg_empty_ids")"
assert_eq "load_config: empty enabled_account_ids returns rc=2" "$(field "$out_empty_ids" RC)" "2"

cfg_no_token="$SANDBOX/cfg-no-token"
mkdir -p "$cfg_no_token"
cat > "$cfg_no_token/config.json" <<'EOF'
{"base_url":"http://127.0.0.1:23373","store_dir":"data/store","enabled_account_ids":["matrix"],"max_chats_per_run":50,"max_pages_per_chat":20}
EOF
out_no_token="$(run_load_config "$cfg_no_token")"
assert_eq "load_config: missing token file returns rc=3" "$(field "$out_no_token" RC)" "3"

# =============================================================================
# 2. cursors.tsv ledger
# =============================================================================

cursor_dir="$SANDBOX/cursor-test"
mkdir -p "$cursor_dir"

run_cursor_tests() {
  (
    CURSORS_FILE="$cursor_dir/cursors.tsv"
    cursor_set "chat-a" "cursor-1"
    a1="$(cursor_get chat-a)"
    cursor_set "chat-a" "cursor-2"
    a2="$(cursor_get chat-a)"
    cursor_set "chat-b" "cursor-b1"
    lines="$(grep -c . "$CURSORS_FILE" 2>/dev/null)"
    unknown_out="$(cursor_get chat-unknown)"
    unknown_rc=$?
    cursor_set "chat-c" 'https://x.example/path?a=1&b=2#frag:!weird'
    weird="$(cursor_get chat-c)"
    echo "A1=$a1"
    echo "A2=$a2"
    echo "LINES=$lines"
    echo "UNKNOWN_OUT=[$unknown_out]"
    echo "UNKNOWN_RC=$unknown_rc"
    echo "WEIRD=$weird"
  )
}

out_cursor="$(run_cursor_tests)"
assert_eq "cursor_set/cursor_get: round-trips" "$(field "$out_cursor" A1)" "cursor-1"
assert_eq "cursor_set: re-set overwrites" "$(field "$out_cursor" A2)" "cursor-2"
assert_eq "cursor ledger: no duplicate lines after re-set (2 chats)" "$(field "$out_cursor" LINES)" "2"
assert_eq "cursor_get: unknown chat returns empty" "$(field "$out_cursor" UNKNOWN_OUT)" "[]"
assert_eq "cursor_get: unknown chat returns rc=1" "$(field "$out_cursor" UNKNOWN_RC)" "1"
assert_eq "cursor ledger: survives URL-ish characters" "$(field "$out_cursor" WEIRD)" 'https://x.example/path?a=1&b=2#frag:!weird'

# =============================================================================
# 3. beeper_get stub injection
# =============================================================================

stub_dir="$SANDBOX/stub-basic"
mkdir -p "$stub_dir"

fixture_body='{"ok":true,"marker":"stub-basic-fixture"}'
fixture_file="$stub_dir/fixture.json"
printf '%s' "$fixture_body" > "$fixture_file"

recording_stub="$stub_dir/stub.sh"
cat > "$recording_stub" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB_LOG"
cat "$STUB_FIXTURE"
EOF
chmod +x "$recording_stub"

# fake curl: if beeper_get ever falls through to curl instead of the stub,
# this leaves a sentinel file we can check for.
fake_bin_dir="$stub_dir/fakebin"
mkdir -p "$fake_bin_dir"
curl_sentinel="$stub_dir/curl-invoked.marker"
cat > "$fake_bin_dir/curl" <<EOF
#!/bin/sh
touch "$curl_sentinel"
exit 77
EOF
chmod +x "$fake_bin_dir/curl"

stub_log="$stub_dir/argv.log"
(
  export PATH="$fake_bin_dir:$PATH"
  export STUB_LOG="$stub_log"
  export STUB_FIXTURE="$fixture_file"
  BEEPER_HTTP_STUB="$recording_stub"
  beeper_get "/v1/info"
) > "$stub_dir/response.out"

assert_eq "beeper_get stub: returns fixture body" "$(cat "$stub_dir/response.out")" "$fixture_body"
assert_eq "beeper_get stub: recorded exactly one call" "$(grep -c . "$stub_log" 2>/dev/null)" "1"
assert_eq "beeper_get stub: recorded the requested path" "$(head -n1 "$stub_log" 2>/dev/null)" "/v1/info"
if [ -e "$curl_sentinel" ]; then
  fail "beeper_get stub: curl was invoked despite BEEPER_HTTP_STUB being set"
else
  pass "beeper_get stub: curl never invoked (fake curl sentinel absent)"
fi

# =============================================================================
# 4. Status lines — run_log format + EXIT trap on every exit path
# =============================================================================

runlog_dir="$SANDBOX/runlog"
mkdir -p "$runlog_dir"

(
  RUNS_LOG="$runlog_dir/ok.log"
  RUN_LOGGED=0
  run_log "ok" 3 5 0
)
ok_line="$(cat "$runlog_dir/ok.log" 2>/dev/null)"
if printf '%s' "$ok_line" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ok chats=3 events=5 quarantined=0$'; then
  pass "run_log: writes the documented format (no warn)"
else
  fail "run_log: unexpected line format: [$ok_line]"
fi

(
  RUNS_LOG="$runlog_dir/warn.log"
  RUN_LOGGED=0
  run_log "partial" 2 1 1 "account xyz not connected"
)
warn_line="$(cat "$runlog_dir/warn.log" 2>/dev/null)"
if printf '%s' "$warn_line" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z partial chats=2 events=1 quarantined=1 warn=account xyz not connected$'; then
  pass "run_log: writes the documented format (with warn)"
else
  fail "run_log: unexpected warn line format: [$warn_line]"
fi

trap_dir="$SANDBOX/trap-test"
mkdir -p "$trap_dir"

no_log_script="$trap_dir/no-log.sh"
cat > "$no_log_script" <<EOF
#!/bin/bash
set -u
source "$LIB"
RUNS_LOG="$trap_dir/no-log-runs.log"
install_run_trap
exit 0
EOF
chmod +x "$no_log_script"
bash "$no_log_script"

no_log_lines="$(grep -c . "$trap_dir/no-log-runs.log" 2>/dev/null)"
assert_eq "EXIT trap: script exiting without run_log writes exactly one line" "$no_log_lines" "1"
if grep -q ' error chats=0 events=0 quarantined=0 warn=exited without logging a run status$' "$trap_dir/no-log-runs.log" 2>/dev/null; then
  pass "EXIT trap: logs an 'error' line when nothing else logged"
else
  fail "EXIT trap: expected error line not found in $trap_dir/no-log-runs.log"
fi

ok_log_script="$trap_dir/ok-log.sh"
cat > "$ok_log_script" <<EOF
#!/bin/bash
set -u
source "$LIB"
RUNS_LOG="$trap_dir/ok-log-runs.log"
install_run_trap
run_log "ok" 1 1 0
exit 0
EOF
chmod +x "$ok_log_script"
bash "$ok_log_script"

ok_log_lines="$(grep -c . "$trap_dir/ok-log-runs.log" 2>/dev/null)"
assert_eq "EXIT trap: script that already logged writes exactly one line (no extra error)" "$ok_log_lines" "1"
if grep -q ' ok chats=1 events=1 quarantined=0$' "$trap_dir/ok-log-runs.log" 2>/dev/null; then
  pass "EXIT trap: does not clobber a script that already called run_log"
else
  fail "EXIT trap: ok line missing/altered in $trap_dir/ok-log-runs.log"
fi

# =============================================================================
# 5. Read-only grep guard — this IS the enforcement for the plan's
#    "no other curl call sites" / "no state-changing paths" rule.
# =============================================================================

strip_comments() {
  # print $1 with full-line comments (lines whose first non-blank char is #)
  # blanked out, so grep below only sees executable code.
  sed -e 's/^[[:space:]]*#.*$//' "$1"
}

guard_files="$(find "$SCRIPTS_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null)"

if [ -z "$guard_files" ]; then
  fail "read-only guard: no shipped scripts found under $SCRIPTS_DIR"
else
  flag_violation=0
  curl_call_sites=0
  state_path_violation=0

  for f in $guard_files; do
    stripped="$(strip_comments "$f")"

    # Scope the -X/--data/-d flag check to lines that actually invoke curl —
    # a whole-file scan false-positives on unrelated uses like `[ -d "$dir" ]`
    # or a script's own `--data-dir` CLI flag, neither of which touch curl.
    curl_lines="$(printf '%s\n' "$stripped" | grep 'curl ')"

    if [ -n "$curl_lines" ] && printf '%s\n' "$curl_lines" | grep -Eq '(^|[[:space:]])-X([[:space:]]|$)'; then
      fail "read-only guard: $f invokes curl with a -X flag"
      flag_violation=1
    fi

    if [ -n "$curl_lines" ] && printf '%s\n' "$curl_lines" | grep -Eq -- '--data|(^|[[:space:]])-d[[:space:]]'; then
      fail "read-only guard: $f invokes curl with --data/-d"
      flag_violation=1
    fi

    site_count="$(printf '%s\n' "$stripped" | grep -c 'curl ')"
    curl_call_sites=$((curl_call_sites + site_count))

    if grep -Eq '/read|/archive|/reminders' "$f"; then
      fail "read-only guard: $f references a state-changing path (/read, /archive, or /reminders)"
      state_path_violation=1
    fi
  done

  if [ "$flag_violation" -eq 0 ]; then
    pass "read-only guard: no -X or --data/-d flags in executable lines of shipped scripts"
  fi

  assert_eq "read-only guard: exactly one curl call site across shipped scripts" "$curl_call_sites" "1"

  if [ "$state_path_violation" -eq 0 ]; then
    pass "read-only guard: no state-changing paths (/read, /archive, /reminders) referenced"
  fi
fi

# =============================================================================
# 6. Pagination helpers — fetch_new_messages, list_new_chats
# =============================================================================

# --- fetch_new_messages, no cursor: exactly one GET, newest page ---
fm_dir="$SANDBOX/fetch-no-cursor"
mkdir -p "$fm_dir"
fm_log="$fm_dir/argv.log"

(
  export STUB_LOG="$fm_log"
  export STUB_FIXTURE="$FIXTURES_DIR/messages-page.json"
  BEEPER_HTTP_STUB="$recording_stub"
  fetch_new_messages "!sample-single-chat:example.org"
) > "$fm_dir/result.json"

encoded_chat="$(beeper_urlencode "!sample-single-chat:example.org")"
expected_path="/v1/chats/${encoded_chat}/messages"

assert_eq "fetch_new_messages (no cursor): exactly one GET" "$(grep -c . "$fm_log" 2>/dev/null)" "1"
assert_eq "fetch_new_messages (no cursor): GET path has no query params" "$(head -n1 "$fm_log" 2>/dev/null)" "$expected_path"

fm_item_count="$(jq '.items | length' "$fm_dir/result.json" 2>/dev/null)"
assert_eq "fetch_new_messages (no cursor): returns all 3 items from the fixture" "$fm_item_count" "3"

fm_final_cursor="$(jq -r '.finalCursor' "$fm_dir/result.json" 2>/dev/null)"
assert_eq "fetch_new_messages (no cursor): finalCursor = fixture newestCursor" "$fm_final_cursor" "cursor-msgs-newest-sample"

# --- fetch_new_messages, with cursor: loops direction=after while hasMore ---
loop_dir="$SANDBOX/fetch-cursor-loop"
mkdir -p "$loop_dir"

hasmore_fixture="$loop_dir/messages-page-hasmore.json"
cat > "$hasmore_fixture" <<'EOF'
{
  "items": [
    {
      "id": "msg-loop-001",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-08-29T15:00:00.000Z",
      "sortKey": "0000000010",
      "type": "TEXT",
      "text": "loop page message",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ],
  "hasMore": true,
  "oldestCursor": "cursor-loop-oldest",
  "newestCursor": "cursor-loop-newest"
}
EOF

seq_stub="$loop_dir/stub-seq.sh"
cat > "$seq_stub" <<'EOF'
#!/bin/sh
echo "$1" >> "$STUB_LOG"
n=$(cat "$STUB_COUNTER")
n=$((n + 1))
echo "$n" > "$STUB_COUNTER"
if [ "$n" -eq 1 ]; then
  cat "$STUB_PAGE1"
else
  cat "$STUB_PAGE2"
fi
EOF
chmod +x "$seq_stub"

loop_log="$loop_dir/argv.log"
loop_counter="$loop_dir/counter"
echo 0 > "$loop_counter"

(
  export STUB_LOG="$loop_log"
  export STUB_COUNTER="$loop_counter"
  export STUB_PAGE1="$hasmore_fixture"
  export STUB_PAGE2="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$seq_stub"
  MAX_PAGES_PER_CHAT=5
  fetch_new_messages "!sample-single-chat:example.org" "cursor-start"
) > "$loop_dir/result.json"

assert_eq "fetch_new_messages (cursor loop): exactly two GETs (page + empty terminator)" "$(grep -c . "$loop_log" 2>/dev/null)" "2"
assert_eq "fetch_new_messages (cursor loop): both pages use direction=after" "$(grep -c 'direction=after' "$loop_log" 2>/dev/null)" "2"

loop_item_count="$(jq '.items | length' "$loop_dir/result.json" 2>/dev/null)"
assert_eq "fetch_new_messages (cursor loop): total items = 1 (empty second page adds none)" "$loop_item_count" "1"

loop_final_cursor="$(jq -r '.finalCursor' "$loop_dir/result.json" 2>/dev/null)"
assert_eq "fetch_new_messages (cursor loop): finalCursor advances to the last page's newestCursor" "$loop_final_cursor" "cursor-msgs-newest-sample"

# --- list_new_chats: repeated accountIDs= query params ---
ln_dir="$SANDBOX/list-chats"
mkdir -p "$ln_dir"
ln_log="$ln_dir/argv.log"

(
  export STUB_LOG="$ln_log"
  export STUB_FIXTURE="$FIXTURES_DIR/chats-page.json"
  BEEPER_HTTP_STUB="$recording_stub"
  ENABLED_ACCOUNT_IDS="$(printf 'matrix\nlocal-whatsapp_ba_test1\n')"
  MAX_CHATS_PER_RUN=50
  list_new_chats
) > "$ln_dir/result.jsonl"

assert_eq "list_new_chats: first run (no since) issues exactly one GET" "$(grep -c . "$ln_log" 2>/dev/null)" "1"

ln_line="$(head -n1 "$ln_log" 2>/dev/null)"
accountids_count="$(printf '%s' "$ln_line" | grep -o 'accountIDs=' | wc -l | tr -d ' ')"
assert_eq "list_new_chats: repeats accountIDs= once per enabled account id" "$accountids_count" "2"

if printf '%s' "$ln_line" | grep -q 'accountIDs=matrix' && printf '%s' "$ln_line" | grep -q 'accountIDs=local-whatsapp_ba_test1'; then
  pass "list_new_chats: both enabled account ids present in the query"
else
  fail "list_new_chats: expected account ids missing from query: $ln_line"
fi

ln_chat_count="$(grep -c . "$ln_dir/result.jsonl" 2>/dev/null)"
assert_eq "list_new_chats: emits one JSON line per chat in the fixture (2)" "$ln_chat_count" "2"

# =============================================================================
# 7. End-to-end: beeper-sweep.sh against the HTTP stub + fixtures, writing
#    into a real mktemp store via the real normalize-capture.sh.
# =============================================================================

SWEEP_SCRIPT="$SCRIPTS_DIR/beeper-sweep.sh"
NORMALIZE_SCRIPT="$REPO_ROOT/packages/connectors/scripts/normalize-capture.sh"

if [ ! -x "$SWEEP_SCRIPT" ]; then
  fail "e2e: beeper-sweep.sh not found/executable at $SWEEP_SCRIPT"
elif [ ! -x "$NORMALIZE_SCRIPT" ]; then
  fail "e2e: normalize-capture.sh not found/executable at $NORMALIZE_SCRIPT"
else

E2E_ROOT="$SANDBOX/e2e"
mkdir -p "$E2E_ROOT"

# make_beeper_config <data_dir> <store_dir_abs> <enabled_ids_space_sep> \
#   [token] — writes config.json + token into a fresh data_dir. Empty
# <enabled_ids_space_sep> writes enabled_account_ids: [].
make_beeper_config() {
  data_dir="$1"
  store_dir_abs="$2"
  ids="$3"
  token="${4:-e2e-test-token}"

  mkdir -p "$data_dir"

  ids_json="[]"
  if [ -n "$ids" ]; then
    ids_json="$(printf '%s\n' $ids | jq -R . | jq -sc .)"
  fi

  cat > "$data_dir/config.json" <<EOF
{
  "base_url": "http://127.0.0.1:23373",
  "store_dir": "$store_dir_abs",
  "enabled_account_ids": $ids_json,
  "max_chats_per_run": 50,
  "max_pages_per_chat": 10
}
EOF

  if [ -n "$token" ]; then
    printf '%s\n' "$token" > "$data_dir/token"
  fi
}

# --- route stub: dispatches by request path to fixture files named by env
# vars, and logs every call (one path per line) to $STUB_LOG. ---
route_stub="$E2E_ROOT/route-stub.sh"
cat > "$route_stub" <<'EOF'
#!/bin/sh
path="$1"
[ -n "${STUB_LOG:-}" ] && echo "$path" >> "$STUB_LOG"
case "$path" in
  /v1/info)
    cat "$STUB_INFO"
    ;;
  /v1/accounts)
    cat "$STUB_ACCOUNTS"
    ;;
  /v1/chats\?*)
    cat "$STUB_CHATS"
    ;;
  */messages\?cursor=*)
    cat "$STUB_MSG_CURSOR"
    ;;
  */messages)
    cat "$STUB_MSG_FIRST"
    ;;
  *)
    echo "e2e route-stub: unmatched path: $path" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$route_stub"

info_body="$E2E_ROOT/info-body.json"
printf '{"ok":true}' > "$info_body"

# =============================================================================
# 7a. Full run: one enabled account matching fixtures; two fixture chats ->
#     two inbox events; runs.log ok line.
# =============================================================================

e2e1_data="$E2E_ROOT/run1/data"
e2e1_store="$E2E_ROOT/run1/store"
mkdir -p "$e2e1_store"
make_beeper_config "$e2e1_data" "$e2e1_store" "matrix local-whatsapp_ba_test1"

e2e1_log="$E2E_ROOT/run1/stub-argv.log"

e2e1_rc=0
(
  export STUB_LOG="$e2e1_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e1_data"
) > "$E2E_ROOT/run1/stdout.log" 2>"$E2E_ROOT/run1/stderr.log"
e2e1_rc=$?

assert_eq "e2e full run: sweep exits 0" "$e2e1_rc" "0"

e2e1_inbox_count="$(find "$e2e1_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e full run: exactly one inbox event per fixture chat (2)" "$e2e1_inbox_count" "2"

e2e1_source_matrix_count="$(grep -l '^source: beeper-in/matrix$' "$e2e1_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "e2e full run: matrix chat's event has source: beeper-in/matrix" "$e2e1_source_matrix_count" "1"

e2e1_source_whatsapp_count="$(grep -l '^source: beeper-in/whatsapp$' "$e2e1_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "e2e full run: whatsapp chat's event has source: beeper-in/whatsapp" "$e2e1_source_whatsapp_count" "1"

e2e1_type_count="$(grep -l '^type: chat-message$' "$e2e1_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "e2e full run: every event has type: chat-message" "$e2e1_type_count" "2"

e2e1_schema_count="$(grep -l '^schema_version: 1.2.0$' "$e2e1_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "e2e full run: every event has schema_version: 1.2.0" "$e2e1_schema_count" "2"

e2e1_occurred_count="$(grep -l '^occurred_at: 2026-08-29T14:32:10Z$' "$e2e1_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "e2e full run: every event has occurred_at matching the fixture's newest timestamp (millis stripped)" "$e2e1_occurred_count" "2"

if grep -rq 'Bea Sample' "$e2e1_store"/inbox/*.md 2>/dev/null; then
  pass "e2e full run: hints include a non-self sender (Bea Sample)"
else
  fail "e2e full run: expected hint 'Bea Sample' not found in any inbox event"
fi

if grep -rlq 'Sample Project Group\|Bea Sample' "$e2e1_store"/inbox/*.md 2>/dev/null; then
  pass "e2e full run: hints include a chat title"
else
  fail "e2e full run: expected a chat title among the hints"
fi

if grep -rq 'hey, are we still on for coffee Friday?' "$e2e1_store"/inbox/*.md 2>/dev/null; then
  pass "e2e full run: body contains a fixture message verbatim"
else
  fail "e2e full run: fixture message text not found verbatim in any inbox event"
fi

e2e1_runlog_last="$(tail -n1 "$e2e1_data/runs.log" 2>/dev/null)"
if printf '%s' "$e2e1_runlog_last" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ok chats=2 events=2 quarantined=0$'; then
  pass "e2e full run: runs.log ends with ok chats=2 events=2 quarantined=0"
else
  fail "e2e full run: unexpected runs.log last line: [$e2e1_runlog_last]"
fi

# =============================================================================
# 7b. Cursor dedup: run the same data/store dirs again; stub now serves
#     messages-empty.json for cursor-bearing requests -> no new events.
# =============================================================================

e2e2_log="$E2E_ROOT/run1/stub-argv-run2.log"

(
  export STUB_LOG="$e2e2_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e1_data"
) > "$E2E_ROOT/run1/stdout-run2.log" 2>"$E2E_ROOT/run1/stderr-run2.log"
e2e2_rc=$?

assert_eq "e2e cursor dedup: second run exits 0" "$e2e2_rc" "0"

e2e2_inbox_count="$(find "$e2e1_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e cursor dedup: no new inbox events (still 2)" "$e2e2_inbox_count" "2"

e2e2_runlog_lines="$(grep -c . "$e2e1_data/runs.log" 2>/dev/null)"
assert_eq "e2e cursor dedup: runs.log gains a second line" "$e2e2_runlog_lines" "2"

if printf '%s\n' "$(grep -c 'cursor=' "$e2e2_log" 2>/dev/null)" | grep -qv '^0$'; then
  pass "e2e cursor dedup: second run requested cursor-bearing message pages"
else
  fail "e2e cursor dedup: expected at least one cursor-bearing request on the second run"
fi

# =============================================================================
# chunk-41 spec 3: content dedup surfaces through the sweep. When the
# normalizer returns 3 (byte-identical body already in inbox/), the chat's
# cursor still advances and the runs.log `ok` line carries `dedup=<n>`
# (separate from `events=`, which does NOT count deduped chats). Uses its
# own single-chat fixture (one enabled account, one fixture chat) so the
# expected dedup count is exactly 1: run the sweep once with fresh
# cursors.tsv (one capture lands), delete cursors.tsv, then run again —
# the stub re-serves the same first-page messages for the now-cursorless
# chat, producing a byte-identical body the second time.
# =============================================================================

e2e_dedup_data="$E2E_ROOT/run-dedup/data"
e2e_dedup_store="$E2E_ROOT/run-dedup/store"
mkdir -p "$e2e_dedup_store"
make_beeper_config "$e2e_dedup_data" "$e2e_dedup_store" "matrix"

e2e_dedup_chats_single="$E2E_ROOT/run-dedup/chats-single.json"
cat > "$e2e_dedup_chats_single" <<'EOF'
{
  "items": [
    {
      "id": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "network": "matrix",
      "title": "Bea Sample",
      "type": "single",
      "participants": {
        "items": [
          { "name": "Ada Test", "ids": ["@ada-test:example.org"] },
          { "name": "Bea Sample", "ids": ["@bea-sample:example.org"] }
        ]
      },
      "lastActivity": "2026-08-29T14:32:10.500Z",
      "unreadCount": 1
    }
  ],
  "hasMore": false,
  "oldestCursor": "cursor-chats-oldest-sample",
  "newestCursor": "cursor-chats-newest-sample"
}
EOF

e2e_dedup_log1="$E2E_ROOT/run-dedup/stub-argv-run1.log"

(
  export STUB_LOG="$e2e_dedup_log1"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$e2e_dedup_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e_dedup_data"
) > "$E2E_ROOT/run-dedup/stdout-run1.log" 2>"$E2E_ROOT/run-dedup/stderr-run1.log"
e2e_dedup_rc1=$?

assert_eq "e2e content dedup: first run exits 0" "$e2e_dedup_rc1" "0"

e2e_dedup_inbox_count_1="$(find "$e2e_dedup_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e content dedup: first run lands exactly one inbox event" "$e2e_dedup_inbox_count_1" "1"

# Reset the incremental cursor ledger so the second run re-fetches the same
# (cursorless) first page for this chat, per the brief's scenario.
rm -f "$e2e_dedup_data/cursors.tsv"

e2e_dedup_log2="$E2E_ROOT/run-dedup/stub-argv-run2.log"

(
  export STUB_LOG="$e2e_dedup_log2"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$e2e_dedup_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e_dedup_data"
) > "$E2E_ROOT/run-dedup/stdout-run2.log" 2>"$E2E_ROOT/run-dedup/stderr-run2.log"
e2e_dedup_rc2=$?

assert_eq "e2e content dedup: second run (cursors reset) exits 0" "$e2e_dedup_rc2" "0"

e2e_dedup_runlog_last="$(tail -n1 "$e2e_dedup_data/runs.log" 2>/dev/null)"
if printf '%s' "$e2e_dedup_runlog_last" | grep -Eq 'ok chats=1 events=0 quarantined=0 dedup=1$'; then
  pass "e2e content dedup: second run's ok line carries events=0 dedup=1 (dedup not counted in events)"
else
  fail "e2e content dedup: unexpected runs.log last line: [$e2e_dedup_runlog_last]"
fi

e2e_dedup_inbox_count_2="$(find "$e2e_dedup_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e content dedup: inbox still has exactly one file for the chat (no new file written)" "$e2e_dedup_inbox_count_2" "1"

if [ -f "$e2e_dedup_data/cursors.tsv" ] && grep -q '^!sample-single-chat:example.org' "$e2e_dedup_data/cursors.tsv" 2>/dev/null; then
  pass "e2e content dedup: cursors.tsv was written on the second run despite the dedup hit (cursor still advances)"
else
  fail "e2e content dedup: cursors.tsv missing or missing the chat's cursor after the second run"
fi

# =============================================================================
# 7c. Unreachable: stub exits 7 (curl-style connect failure) on /v1/info.
# =============================================================================

e2e3_data="$E2E_ROOT/run3/data"
e2e3_store="$E2E_ROOT/run3/store"
mkdir -p "$e2e3_store"
make_beeper_config "$e2e3_data" "$e2e3_store" "matrix local-whatsapp_ba_test1"

unreachable_stub="$E2E_ROOT/run3/unreachable-stub.sh"
cat > "$unreachable_stub" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$unreachable_stub"

(
  BEEPER_HTTP_STUB="$unreachable_stub" "$SWEEP_SCRIPT" --data-dir "$e2e3_data"
) > "$E2E_ROOT/run3/stdout.log" 2>"$E2E_ROOT/run3/stderr.log"
e2e3_rc=$?

assert_eq "e2e unreachable: sweep exits 0" "$e2e3_rc" "0"

e2e3_runlog_last="$(tail -n1 "$e2e3_data/runs.log" 2>/dev/null)"
if printf '%s' "$e2e3_runlog_last" | grep -Eq 'skip-unreachable chats=0 events=0 quarantined=0$'; then
  pass "e2e unreachable: runs.log logs skip-unreachable"
else
  fail "e2e unreachable: unexpected runs.log last line: [$e2e3_runlog_last]"
fi

e2e3_inbox_count="$(find "$e2e3_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e unreachable: inbox stays empty" "$e2e3_inbox_count" "0"

# =============================================================================
# 7d. Disabled: empty enabled_account_ids -> skip-disabled, no HTTP calls.
# =============================================================================

e2e4_data="$E2E_ROOT/run4/data"
e2e4_store="$E2E_ROOT/run4/store"
mkdir -p "$e2e4_store"
make_beeper_config "$e2e4_data" "$e2e4_store" ""

e2e4_log="$E2E_ROOT/run4/stub-argv.log"

(
  export STUB_LOG="$e2e4_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e4_data"
) > "$E2E_ROOT/run4/stdout.log" 2>"$E2E_ROOT/run4/stderr.log"
e2e4_rc=$?

assert_eq "e2e disabled: sweep exits 0" "$e2e4_rc" "0"

e2e4_runlog_last="$(tail -n1 "$e2e4_data/runs.log" 2>/dev/null)"
if printf '%s' "$e2e4_runlog_last" | grep -Eq 'skip-disabled chats=0 events=0 quarantined=0$'; then
  pass "e2e disabled: runs.log logs skip-disabled"
else
  fail "e2e disabled: unexpected runs.log last line: [$e2e4_runlog_last]"
fi

e2e4_stub_calls="$(grep -c . "$e2e4_log" 2>/dev/null)"
[ -z "$e2e4_stub_calls" ] && e2e4_stub_calls=0
assert_eq "e2e disabled: no HTTP calls recorded by the stub" "$e2e4_stub_calls" "0"

# =============================================================================
# 7e. Normalizer failure path: force a deterministic id collision so the
#     second chat processed is quarantined by normalize-capture.sh while the
#     first succeeds. The default id is
#     <captured_at-compact>-<source>-<4-hex-rand>, and --source is now
#     "beeper-in/<network>" (per-chat, from each chat's own JSON) rather than
#     a constant "beeper" — the shared fixtures/chats-page.json gives the two
#     sample chats different networks (matrix, whatsapp), so their sources
#     no longer collide. This subtest uses its own test-local chats fixture
#     (same chat ids/participants as fixtures/chats-page.json, just both
#     chats' "network" field pinned to "matrix") so both events compute the
#     same --source beeper-in/matrix; both chats share the same captured_at
#     (fixed per run), so the only remaining variable is the normalizer's
#     random hex suffix — a fake `openssl` ahead of the real one on PATH pins
#     that suffix to a constant, making the collision deterministic (same
#     technique as the existing dup-id case in run-capture-tests.sh, just
#     driven from the sweep side instead of an explicit --id).
# =============================================================================

e2e5_data="$E2E_ROOT/run5/data"
e2e5_store="$E2E_ROOT/run5/store"
mkdir -p "$e2e5_store"
make_beeper_config "$e2e5_data" "$e2e5_store" "matrix local-whatsapp_ba_test1"

fake_openssl_dir="$E2E_ROOT/run5/fake-openssl-bin"
mkdir -p "$fake_openssl_dir"
cat > "$fake_openssl_dir/openssl" <<'EOF'
#!/bin/sh
echo "aaaa"
EOF
chmod +x "$fake_openssl_dir/openssl"

e2e5_chats_same_network="$E2E_ROOT/run5/chats-page-same-network.json"
cat > "$e2e5_chats_same_network" <<'EOF'
{
  "items": [
    {
      "id": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "network": "matrix",
      "title": "Bea Sample",
      "type": "single",
      "participants": {
        "items": [
          { "name": "Ada Test", "ids": ["@ada-test:example.org"] },
          { "name": "Bea Sample", "ids": ["@bea-sample:example.org"] }
        ]
      },
      "lastActivity": "2026-08-29T14:32:10.500Z",
      "unreadCount": 1
    },
    {
      "id": "local-whatsapp_ba_test1_group-sample",
      "accountID": "local-whatsapp_ba_test1",
      "network": "matrix",
      "title": "Sample Project Group",
      "type": "group",
      "participants": {
        "items": [
          { "name": "Ada Test", "ids": ["test-user-1"] },
          { "name": "Cy Sample", "ids": ["whatsapp-cy-sample"] },
          { "name": "Dee Sample", "ids": ["whatsapp-dee-sample"] }
        ]
      },
      "lastActivity": "2026-08-29T13:05:44.120Z",
      "unreadCount": 0
    }
  ],
  "hasMore": false,
  "oldestCursor": "cursor-chats-oldest-sample",
  "newestCursor": "cursor-chats-newest-sample"
}
EOF

e2e5_log="$E2E_ROOT/run5/stub-argv.log"

(
  export PATH="$fake_openssl_dir:$PATH"
  export STUB_LOG="$e2e5_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$e2e5_chats_same_network"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$e2e5_data"
) > "$E2E_ROOT/run5/stdout.log" 2>"$E2E_ROOT/run5/stderr.log"
e2e5_rc=$?

assert_eq "e2e normalizer failure: sweep exits 0" "$e2e5_rc" "0"

e2e5_inbox_count="$(find "$e2e5_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e normalizer failure: exactly one chat's event lands in inbox" "$e2e5_inbox_count" "1"

e2e5_quarantine_count="$(find "$e2e5_store/inbox/quarantine" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "e2e normalizer failure: exactly one chat is quarantined" "$e2e5_quarantine_count" "1"

e2e5_runlog_last="$(tail -n1 "$e2e5_data/runs.log" 2>/dev/null)"
if printf '%s' "$e2e5_runlog_last" | grep -Eq 'partial chats=2 events=1 quarantined=1$'; then
  pass "e2e normalizer failure: runs.log logs partial chats=2 events=1 quarantined=1"
else
  fail "e2e normalizer failure: unexpected runs.log last line: [$e2e5_runlog_last]"
fi

e2e5_cursors="$e2e5_data/cursors.tsv"
e2e5_cursor_lines="$(grep -c . "$e2e5_cursors" 2>/dev/null)"
assert_eq "e2e normalizer failure: only the succeeding chat's cursor is recorded" "$e2e5_cursor_lines" "1"

if grep -q '^!sample-single-chat:example.org' "$e2e5_cursors" 2>/dev/null; then
  pass "e2e normalizer failure: the succeeding (first-processed) chat's cursor advanced"
else
  fail "e2e normalizer failure: expected matrix chat's cursor entry missing from cursors.tsv"
fi

if grep -q '^local-whatsapp_ba_test1_group-sample' "$e2e5_cursors" 2>/dev/null; then
  fail "e2e normalizer failure: quarantined chat's cursor was advanced (must not be)"
else
  pass "e2e normalizer failure: quarantined chat's cursor was NOT advanced"
fi

fi # SWEEP_SCRIPT / NORMALIZE_SCRIPT present

# =============================================================================
# 8. --backfill mode (plan 24 U6/U11). Same route_stub + fixture harness as
#    section 7, plus resolve-backfill-window.sh (called directly to pin the
#    window boundary for the straddling-page test). <data-root> layout:
#    <root>/connectors/beeper-in is the --data-dir passed to beeper-sweep.sh
#    (so it can strip two segments back to <root> the same way the sweep
#    script itself does); <root>/config/onboarding-backfill.tsv is optional
#    per-test config.
# =============================================================================

RESOLVE_WINDOW_SCRIPT="$REPO_ROOT/packages/connectors/scripts/resolve-backfill-window.sh"

if [ ! -x "$SWEEP_SCRIPT" ] || [ ! -x "$NORMALIZE_SCRIPT" ]; then
  fail "backfill: beeper-sweep.sh or normalize-capture.sh not found/executable — skipping backfill subtests"
elif [ ! -x "$RESOLVE_WINDOW_SCRIPT" ]; then
  fail "backfill: resolve-backfill-window.sh not found/executable at $RESOLVE_WINDOW_SCRIPT"
else

BF_ROOT="$SANDBOX/backfill"
mkdir -p "$BF_ROOT"

# =============================================================================
# 8a. Isolation: a --backfill-only run (no prior incremental run) must write
#     backfill-cursors.tsv + backfill-last-sweep, and must NOT create
#     cursors.tsv / last-sweep (the incremental ledger) at all.
# =============================================================================

bf1_root="$BF_ROOT/1-isolation"
bf1_data_root="$bf1_root/data-root"
bf1_data="$bf1_data_root/connectors/beeper-in"
bf1_store="$bf1_root/store"
mkdir -p "$bf1_store" "$bf1_data"
make_beeper_config "$bf1_data" "$bf1_store" "matrix local-whatsapp_ba_test1"

bf1_log="$bf1_root/stub-argv.log"

(
  export STUB_LOG="$bf1_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf1_data" --backfill
) > "$bf1_root/stdout.log" 2>"$bf1_root/stderr.log"
bf1_rc=$?

assert_eq "backfill isolation: sweep exits 0" "$bf1_rc" "0"

if [ -f "$bf1_data/backfill-cursors.tsv" ]; then
  pass "backfill isolation: backfill-cursors.tsv was created"
else
  fail "backfill isolation: backfill-cursors.tsv missing at $bf1_data/backfill-cursors.tsv"
fi

if [ -f "$bf1_data/backfill-last-sweep" ]; then
  pass "backfill isolation: backfill-last-sweep was created"
else
  fail "backfill isolation: backfill-last-sweep missing at $bf1_data/backfill-last-sweep"
fi

if [ -f "$bf1_data/cursors.tsv" ]; then
  fail "backfill isolation: cursors.tsv was created by a --backfill-only run (must stay absent)"
else
  pass "backfill isolation: cursors.tsv (incremental ledger) stays absent"
fi

if [ -f "$bf1_data/last-sweep" ]; then
  fail "backfill isolation: last-sweep was created by a --backfill-only run (must stay absent)"
else
  pass "backfill isolation: last-sweep (incremental ledger) stays absent"
fi

# D6: fixtures/messages-page.json is a single hasMore:false page, so both
# chats' newest-page fetch exhausts bridge history immediately — the
# correct, expected outcome is a history-clamped WARN per chat (D6 fetch_
# backfill_messages sets clamped whenever has_more != true, regardless of
# whether the page is genuinely at the window edge). Isolation intent
# (backfill-cursors.tsv/backfill-last-sweep created, cursors.tsv/last-sweep
# absent) is unaffected and asserted separately above; asserting the WARN
# here documents the D6 clamp semantics rather than weakening this check.
bf1_runlog_last="$(tail -n1 "$bf1_data/runs.log" 2>/dev/null)"
if printf '%s' "$bf1_runlog_last" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z backfill-ok chats=2 events=2 quarantined=0 warn=!sample-single-chat:example\.org=history-clamped@2026-08-29T14:30:00\.000Z,local-whatsapp_ba_test1_group-sample=history-clamped@2026-08-29T14:30:00\.000Z$'; then
  pass "backfill isolation: runs.log carries the backfill- outcome prefix and the expected history-clamped WARN for both chats (D6: single-page hasMore:false fixture)"
else
  fail "backfill isolation: unexpected runs.log last line: [$bf1_runlog_last]"
fi

# =============================================================================
# 8b. Window bound: a page straddling the window start must have its
#     older-than-window items filtered out. Timestamps are computed from the
#     actual window boundary (window_months=1, resolved for real) rather than
#     hardcoded, so this test is immune to drift in "now".
# =============================================================================

bf2_root="$BF_ROOT/2-window-bound"
bf2_data_root="$bf2_root/data-root"
bf2_data="$bf2_data_root/connectors/beeper-in"
bf2_store="$bf2_root/store"
mkdir -p "$bf2_store" "$bf2_data" "$bf2_data_root/config"
make_beeper_config "$bf2_data" "$bf2_store" "matrix local-whatsapp_ba_test1"
printf 'window_months\t1\n' > "$bf2_data_root/config/onboarding-backfill.tsv"

bf2_window_line="$("$RESOLVE_WINDOW_SCRIPT" "$bf2_data_root")"
bf2_window_start="$(printf '%s' "$bf2_window_line" | cut -f1)"

if [ -z "$bf2_window_start" ]; then
  fail "backfill window bound: could not resolve a window start to pin the test to"
else
  if date -u -d '@0' +%s >/dev/null 2>&1; then
    bf2_in_ts="$(TZ=UTC date -u -d "$bf2_window_start + 1 day" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)"
    bf2_out_ts="$(TZ=UTC date -u -d "$bf2_window_start - 1 day" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)"
  else
    bf2_in_ts="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' -v+1d "$bf2_window_start" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)"
    bf2_out_ts="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' -v-1d "$bf2_window_start" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null)"
  fi

  bf2_straddle_fixture="$bf2_root/messages-straddle.json"
  cat > "$bf2_straddle_fixture" <<EOF
{
  "items": [
    {
      "id": "msg-bf-in-window",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "$bf2_in_ts",
      "sortKey": "0000000002",
      "type": "TEXT",
      "text": "IN-WINDOW-MESSAGE-MARKER",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-bf-out-window",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "$bf2_out_ts",
      "sortKey": "0000000001",
      "type": "TEXT",
      "text": "OUT-OF-WINDOW-MESSAGE-MARKER",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ],
  "hasMore": false,
  "oldestCursor": "cursor-bf-straddle-oldest",
  "newestCursor": "cursor-bf-straddle-newest"
}
EOF

  bf2_log="$bf2_root/stub-argv.log"
  (
    export STUB_LOG="$bf2_log"
    export STUB_INFO="$info_body"
    export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
    export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
    export STUB_MSG_FIRST="$bf2_straddle_fixture"
    export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
    BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf2_data" --backfill
  ) > "$bf2_root/stdout.log" 2>"$bf2_root/stderr.log"
  bf2_rc=$?

  assert_eq "backfill window bound: sweep exits 0" "$bf2_rc" "0"

  if grep -rq 'IN-WINDOW-MESSAGE-MARKER' "$bf2_store"/inbox/*.md 2>/dev/null; then
    pass "backfill window bound: in-window message was captured"
  else
    fail "backfill window bound: expected in-window message not found in any inbox event"
  fi

  if grep -rq 'OUT-OF-WINDOW-MESSAGE-MARKER' "$bf2_store"/inbox/*.md 2>/dev/null; then
    fail "backfill window bound: out-of-window message leaked into a captured inbox event"
  else
    pass "backfill window bound: out-of-window message was filtered out (not captured)"
  fi
fi

# =============================================================================
# 8c. No duplicate coverage: a --backfill run AFTER an incremental run must
#     request older history (cursor=<incremental cursor>&direction=before)
#     and must not re-capture the messages the incremental run already
#     covered.
# =============================================================================

bf3_root="$BF_ROOT/3-no-dup-coverage"
bf3_data_root="$bf3_root/data-root"
bf3_data="$bf3_data_root/connectors/beeper-in"
bf3_store="$bf3_root/store"
mkdir -p "$bf3_store" "$bf3_data"
make_beeper_config "$bf3_data" "$bf3_store" "matrix local-whatsapp_ba_test1"

bf3_incr_log="$bf3_root/stub-argv-incremental.log"
(
  export STUB_LOG="$bf3_incr_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf3_data"
) > "$bf3_root/stdout-incremental.log" 2>"$bf3_root/stderr-incremental.log"
bf3_incr_rc=$?
assert_eq "backfill no-dup coverage: prior incremental run exits 0" "$bf3_incr_rc" "0"

bf3_bf_log="$bf3_root/stub-argv-backfill.log"
(
  export STUB_LOG="$bf3_bf_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-page-backfill-older.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf3_data" --backfill
) > "$bf3_root/stdout-backfill.log" 2>"$bf3_root/stderr-backfill.log"
bf3_bf_rc=$?
assert_eq "backfill no-dup coverage: backfill run exits 0" "$bf3_bf_rc" "0"

if grep -q 'direction=before' "$bf3_bf_log" 2>/dev/null && grep -q 'cursor=' "$bf3_bf_log" 2>/dev/null; then
  pass "backfill no-dup coverage: backfill requested cursor-bound direction=before pages (fetching only older history)"
else
  fail "backfill no-dup coverage: expected a cursor-bound direction=before request in $bf3_bf_log"
fi

if grep -rq 'msg-bf-older-001' "$bf3_store"/inbox/*.md 2>/dev/null; then
  pass "backfill no-dup coverage: backfill captured the genuinely-older fixture message"
else
  fail "backfill no-dup coverage: expected older-fixture message id not found in any inbox event"
fi

# msg-sample-001/002/003 are the incremental fixture's message ids: the
# backfill run must not re-request/re-capture them (it fetched the "older"
# fixture instead, driven by direction=before + the incremental cursor).
# The shared messages-page.json fixture is chat-agnostic (same message ids
# regardless of which chat requests it), so both of the incremental run's
# two chats produce one inbox event apiece containing these ids — that's the
# ceiling. The no-dup-coverage property is that the *backfill* run's
# request/response never touched them (established by the direction=before +
# cursor= assertion above): if backfill had re-captured them, this count
# would grow past that ceiling (to 3 or 4, from backfill's own two chats).
bf3_dup_ids="$(grep -rl 'msg-sample-00[123]' "$bf3_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "backfill no-dup coverage: incremental fixture's message ids appear only in the incremental run's own events (2 chats), never re-captured by backfill" "$bf3_dup_ids" "2"

# =============================================================================
# 8d. Incremental unaffected: an incremental run's cursor advancement is
#     identical whether or not a --backfill run happened in between.
# =============================================================================

incr_stub_run() {
  # $1 = data_dir — runs one incremental sweep with the shared stub/fixtures.
  (
    export STUB_LOG="$(mktemp)"
    export STUB_INFO="$info_body"
    export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
    export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
    export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
    export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
    BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$1"
  ) > /dev/null 2>&1
}

bf4a_root="$BF_ROOT/4a-baseline"
bf4a_data="$bf4a_root/data-root/connectors/beeper-in"
bf4a_store="$bf4a_root/store"
mkdir -p "$bf4a_store" "$bf4a_data"
make_beeper_config "$bf4a_data" "$bf4a_store" "matrix local-whatsapp_ba_test1"
incr_stub_run "$bf4a_data"
incr_stub_run "$bf4a_data"

bf4b_root="$BF_ROOT/4b-with-backfill"
bf4b_data="$bf4b_root/data-root/connectors/beeper-in"
bf4b_store="$bf4b_root/store"
mkdir -p "$bf4b_store" "$bf4b_data"
make_beeper_config "$bf4b_data" "$bf4b_store" "matrix local-whatsapp_ba_test1"
incr_stub_run "$bf4b_data"
(
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-page-backfill-older.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf4b_data" --backfill
) > /dev/null 2>&1
# The backfill run legitimately adds its own inbox events (older history) —
# that's not a violation. What "incremental unaffected" means is that the
# trailing incremental run's own contribution is unchanged: count events
# right after the interleaved backfill, then confirm the final incremental
# run adds none (same no-op behavior as the baseline's second run).
bf4b_events_post_backfill="$(find "$bf4b_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
incr_stub_run "$bf4b_data"
bf4b_events_final="$(find "$bf4b_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"

if diff -q "$bf4a_data/cursors.tsv" "$bf4b_data/cursors.tsv" >/dev/null 2>&1; then
  pass "backfill incremental-unaffected: second incremental run's cursors.tsv is identical with/without an interleaved backfill run"
else
  fail "backfill incremental-unaffected: cursors.tsv diverged — diff: $(diff "$bf4a_data/cursors.tsv" "$bf4b_data/cursors.tsv" 2>&1 | tr '\n' ' ')"
fi

assert_eq "backfill incremental-unaffected: the trailing incremental run adds zero new inbox events after an interleaved backfill (same no-op as the baseline's second run)" "$bf4b_events_final" "$bf4b_events_post_backfill"

# =============================================================================
# 8e. Default-window pin (contract check): with NO
#     <data-root>/config/onboarding-backfill.tsv present, --backfill must
#     still run using the default 6-month window (missing file is valid per
#     packages/core/contracts/onboarding-backfill.md — the helper defaults
#     window_months to 6). Per the brief: if the implementation instead
#     skips/errors here, this assertion is left as a documented expected-fail
#     rather than silently patched, and reported as a finding.
# =============================================================================

bf5_root="$BF_ROOT/5-default-window"
bf5_data_root="$bf5_root/data-root"
bf5_data="$bf5_data_root/connectors/beeper-in"
bf5_store="$bf5_root/store"
mkdir -p "$bf5_store" "$bf5_data"
make_beeper_config "$bf5_data" "$bf5_store" "matrix local-whatsapp_ba_test1"
# Deliberately no $bf5_data_root/config/onboarding-backfill.tsv.

bf5_log="$bf5_root/stub-argv.log"
(
  export STUB_LOG="$bf5_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$bf5_data" --backfill
) > "$bf5_root/stdout.log" 2>"$bf5_root/stderr.log"
bf5_rc=$?

assert_eq "backfill default-window pin: sweep exits 0 with no onboarding-backfill.tsv present" "$bf5_rc" "0"

# D6: fixtures/messages-page.json is a single hasMore:false page, so both
# chats' newest-page fetch exhausts bridge history immediately — the
# correct, expected outcome under the default 6-month window is a
# history-clamped WARN per chat (same D6 clamp semantics as 8a). The
# default-window-pin intent (no skip/error when onboarding-backfill.tsv is
# absent) is unaffected — the outcome is still backfill-ok, not a
# skip/error — so this only adjusts the WARN expectation, not that intent.
bf5_runlog_last="$(tail -n1 "$bf5_data/runs.log" 2>/dev/null)"
if printf '%s' "$bf5_runlog_last" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z backfill-ok chats=2 events=2 quarantined=0 warn=!sample-single-chat:example\.org=history-clamped@2026-08-29T14:30:00\.000Z,local-whatsapp_ba_test1_group-sample=history-clamped@2026-08-29T14:30:00\.000Z$'; then
  pass "backfill default-window pin: runs with the default 6-month window (no skip/error) per onboarding-backfill.md's missing-file-is-valid rule, and carries the expected history-clamped WARN for both chats (D6: single-page hasMore:false fixture)"
else
  fail "backfill default-window pin: expected a backfill-ok run using the default window; got runs.log last line: [$bf5_runlog_last]"
fi

fi # SWEEP_SCRIPT / NORMALIZE_SCRIPT / RESOLVE_WINDOW_SCRIPT present

# =============================================================================
# 9. D6 backfill fix regression tests (coverage-floor.tsv write-once guard,
#    backfill start-bound resolution via the floor / legacy fallback, and the
#    history-clamped WARN). Same route_stub + fixture harness as sections
#    7-8, plus a small set of test-local fixtures/stubs unique to these
#    properties (defined inline below, same convention as 7e/8b's ad hoc
#    fixtures). Uses a single-chat variant of fixtures/chats-page.json
#    (chats-single.json, matrix chat only) to keep dup/legacy/clamp
#    assertions unambiguous (one chat, one event per run).
# =============================================================================

if [ ! -x "$SWEEP_SCRIPT" ] || [ ! -x "$NORMALIZE_SCRIPT" ] || [ ! -x "$RESOLVE_WINDOW_SCRIPT" ]; then
  fail "d6: beeper-sweep.sh, normalize-capture.sh, or resolve-backfill-window.sh not found/executable — skipping D6 regression subtests"
else

D6_ROOT="$SANDBOX/d6-coverage-floor"
mkdir -p "$D6_ROOT"

d6_chats_single="$D6_ROOT/chats-single.json"
cat > "$d6_chats_single" <<'EOF'
{
  "items": [
    {
      "id": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "network": "matrix",
      "title": "Bea Sample",
      "type": "single",
      "participants": {
        "items": [
          { "name": "Ada Test", "ids": ["@ada-test:example.org"] },
          { "name": "Bea Sample", "ids": ["@bea-sample:example.org"] }
        ]
      },
      "lastActivity": "2026-08-29T14:32:10.500Z",
      "unreadCount": 1
    }
  ],
  "hasMore": false,
  "oldestCursor": "cursor-chats-oldest-sample",
  "newestCursor": "cursor-chats-newest-sample"
}
EOF

# Genuinely older, non-overlapping history (D6's correct backfill start
# bound): no oldestCursor -> also exercises the history-clamped path (9d).
d6_msgs_older="$D6_ROOT/messages-genuinely-older.json"
cat > "$d6_msgs_older" <<'EOF'
{
  "items": [
    {
      "id": "msg-d6-older-001",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-06-15T10:00:00.000Z",
      "sortKey": "0000000000",
      "type": "TEXT",
      "text": "D6 backfill regression: genuinely older history, no overlap with incremental",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ],
  "hasMore": false,
  "newestCursor": "cursor-d6-older-newest"
}
EOF

# Sabotage-only fixture: duplicates the incremental capture's own message
# ids/timestamps. Only ever served if backfill's start-bound resolution
# regresses to the incremental cursor (cursor-msgs-newest-sample) instead of
# the coverage floor (cursor-msgs-oldest-sample) — see 9b's d6b_route_stub.
d6_msgs_sabotage_overlap="$D6_ROOT/messages-sabotage-overlap.json"
cat > "$d6_msgs_sabotage_overlap" <<'EOF'
{
  "items": [
    {
      "id": "msg-sample-001",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-08-29T14:30:00.000Z",
      "sortKey": "0000000001",
      "type": "TEXT",
      "text": "Sample message: hey, are we still on for coffee Friday?",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-sample-002",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@ada-test:example.org",
      "senderName": "Ada Test",
      "timestamp": "2026-08-29T14:31:20.250Z",
      "sortKey": "0000000002",
      "type": "TEXT",
      "text": "Sample message: yep, 10am works for me",
      "isSender": true,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-sample-003",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-08-29T14:32:10.500Z",
      "sortKey": "0000000003",
      "type": "IMAGE",
      "text": "Sample message: here's the cafe location",
      "isSender": false,
      "attachments": [
        { "url": "mxc://example.org/sampleMediaId123", "type": "image" }
      ],
      "linkedMessageID": null,
      "reactions": []
    }
  ],
  "hasMore": false,
  "newestCursor": "cursor-sabotage-newest"
}
EOF

# Legacy no-floor fallback fixture: one genuinely-older message plus a
# message whose id/timestamp exactly matches an already-captured message
# (msg-sample-001 from fixtures/messages-page.json) — the latter must be
# excluded by the legacy_max_ts filter.
d6_msgs_legacy_mixed="$D6_ROOT/messages-legacy-mixed.json"
cat > "$d6_msgs_legacy_mixed" <<'EOF'
{
  "items": [
    {
      "id": "msg-legacy-old-001",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-06-01T09:00:00.000Z",
      "sortKey": "0000000000",
      "type": "TEXT",
      "text": "Legacy backfill message: genuinely older than the first incremental capture",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-sample-001",
      "chatID": "!sample-single-chat:example.org",
      "accountID": "matrix",
      "senderID": "@bea-sample:example.org",
      "senderName": "Bea Sample",
      "timestamp": "2026-08-29T14:30:00.000Z",
      "sortKey": "0000000001",
      "type": "TEXT",
      "text": "Sample message: hey, are we still on for coffee Friday?",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ],
  "hasMore": false,
  "newestCursor": "cursor-legacy-mixed-newest"
}
EOF

# assert_no_dup_subset_events <store_dir> <description> — property (i): no
# inbox capture event's message-id set is a subset of (or equal to) a prior
# event's message-id set. Compares every ordered pair of inbox .md files'
# body `messages[].id` sets.
assert_no_dup_subset_events() {
  store_dir="$1"
  desc="$2"
  ids_dir="$(mktemp -d)"
  n=0
  for f in "$store_dir"/inbox/*.md; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    body="$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$f")"
    printf '%s' "$body" | jq -r '.messages[].id' 2>/dev/null | sort > "$ids_dir/$n.ids"
  done

  violation=0
  a=1
  while [ "$a" -le "$n" ]; do
    b=1
    while [ "$b" -le "$n" ]; do
      if [ "$a" -ne "$b" ] && [ -s "$ids_dir/$a.ids" ]; then
        leftover="$(comm -23 "$ids_dir/$a.ids" "$ids_dir/$b.ids" 2>/dev/null)"
        if [ -z "$leftover" ]; then
          violation=1
        fi
      fi
      b=$((b + 1))
    done
    a=$((a + 1))
  done
  rm -rf "$ids_dir"

  if [ "$violation" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc (found an inbox event whose message-id set is a subset of another's)"
  fi
}

# -----------------------------------------------------------------------
# 9a. coverage-floor.tsv: written once on first incremental capture,
#     unchanged by a second incremental run, unchanged by a --backfill run.
# -----------------------------------------------------------------------
d6a_root="$D6_ROOT/9a-write-once"
d6a_data_root="$d6a_root/data-root"
d6a_data="$d6a_data_root/connectors/beeper-in"
d6a_store="$d6a_root/store"
mkdir -p "$d6a_store" "$d6a_data"
make_beeper_config "$d6a_data" "$d6a_store" "matrix"

d6a_log1="$d6a_root/stub-argv-1.log"
(
  export STUB_LOG="$d6a_log1"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6a_data"
) > "$d6a_root/stdout-1.log" 2>"$d6a_root/stderr-1.log"
d6a_rc1=$?
assert_eq "d6 write-once: first incremental run exits 0" "$d6a_rc1" "0"

d6a_floor="$d6a_data/coverage-floor.tsv"
assert_eq "d6 write-once: coverage-floor.tsv has exactly one line after first capture" "$(grep -c . "$d6a_floor" 2>/dev/null)" "1"

d6a_floor_after1="$(cat "$d6a_floor" 2>/dev/null)"
if printf '%s' "$d6a_floor_after1" | grep -q 'cursor-msgs-oldest-sample$'; then
  pass "d6 write-once: coverage-floor.tsv records the first page's oldest cursor"
else
  fail "d6 write-once: unexpected coverage-floor.tsv content: [$d6a_floor_after1]"
fi

d6a_log2="$d6a_root/stub-argv-2.log"
(
  export STUB_LOG="$d6a_log2"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6a_data"
) > "$d6a_root/stdout-2.log" 2>"$d6a_root/stderr-2.log"
d6a_rc2=$?
assert_eq "d6 write-once: second incremental run exits 0" "$d6a_rc2" "0"

d6a_floor_after2="$(cat "$d6a_floor" 2>/dev/null)"
assert_eq "d6 write-once: coverage-floor.tsv unchanged after a second incremental run" "$d6a_floor_after2" "$d6a_floor_after1"

d6a_log3="$d6a_root/stub-argv-3.log"
(
  export STUB_LOG="$d6a_log3"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$d6_msgs_older"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6a_data" --backfill
) > "$d6a_root/stdout-3.log" 2>"$d6a_root/stderr-3.log"
d6a_rc3=$?
assert_eq "d6 write-once: backfill run exits 0" "$d6a_rc3" "0"

d6a_floor_after3="$(cat "$d6a_floor" 2>/dev/null)"
assert_eq "d6 write-once: coverage-floor.tsv unchanged after a --backfill run (backfill never writes it)" "$d6a_floor_after3" "$d6a_floor_after1"

# -----------------------------------------------------------------------
# 9b. No duplicate-subset events: incremental first-capture then --backfill
#     over the same stub history produces no overlapping message-id sets.
#     Uses a cursor-value-aware stub (d6b_route_stub) so a start-bound
#     regression (backfill resuming from the incremental cursor instead of
#     the coverage floor) is distinguishable: the "before floor" cursor
#     (cursor-msgs-oldest-sample) serves genuinely older, non-overlapping
#     history; the "before newest" cursor (cursor-msgs-newest-sample) —
#     only ever requested if beeper-sweep.sh's D6 fix regresses — serves a
#     fixture that duplicates the incremental capture's own message ids.
# -----------------------------------------------------------------------
d6b_root="$D6_ROOT/9b-no-dup-subset"
d6b_data_root="$d6b_root/data-root"
d6b_data="$d6b_data_root/connectors/beeper-in"
d6b_store="$d6b_root/store"
mkdir -p "$d6b_store" "$d6b_data"
make_beeper_config "$d6b_data" "$d6b_store" "matrix"

d6b_route_stub="$d6b_root/route-stub.sh"
cat > "$d6b_route_stub" <<'EOF'
#!/bin/sh
path="$1"
[ -n "${STUB_LOG:-}" ] && echo "$path" >> "$STUB_LOG"
case "$path" in
  /v1/info)
    cat "$STUB_INFO"
    ;;
  /v1/accounts)
    cat "$STUB_ACCOUNTS"
    ;;
  /v1/chats\?*)
    cat "$STUB_CHATS"
    ;;
  */messages\?cursor=cursor-msgs-oldest-sample\&direction=before)
    cat "$STUB_MSG_BEFORE_FLOOR"
    ;;
  */messages\?cursor=cursor-msgs-newest-sample\&direction=before)
    cat "$STUB_MSG_BEFORE_NEWEST"
    ;;
  */messages)
    cat "$STUB_MSG_FIRST"
    ;;
  *)
    echo "d6b route-stub: unmatched path: $path" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$d6b_route_stub"

d6b_log1="$d6b_root/stub-argv-1.log"
(
  export STUB_LOG="$d6b_log1"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  BEEPER_HTTP_STUB="$d6b_route_stub" "$SWEEP_SCRIPT" --data-dir "$d6b_data"
) > "$d6b_root/stdout-1.log" 2>"$d6b_root/stderr-1.log"
d6b_rc1=$?
assert_eq "d6 no-dup-subset: incremental run exits 0" "$d6b_rc1" "0"

d6b_log2="$d6b_root/stub-argv-2.log"
(
  export STUB_LOG="$d6b_log2"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_BEFORE_FLOOR="$d6_msgs_older"
  export STUB_MSG_BEFORE_NEWEST="$d6_msgs_sabotage_overlap"
  BEEPER_HTTP_STUB="$d6b_route_stub" "$SWEEP_SCRIPT" --data-dir "$d6b_data" --backfill
) > "$d6b_root/stdout-2.log" 2>"$d6b_root/stderr-2.log"
d6b_rc2=$?
assert_eq "d6 no-dup-subset: backfill run exits 0" "$d6b_rc2" "0"

if grep -q 'cursor=cursor-msgs-oldest-sample&direction=before' "$d6b_log2" 2>/dev/null; then
  pass "d6 no-dup-subset: backfill started from the coverage-floor cursor (not the incremental cursor)"
else
  fail "d6 no-dup-subset: backfill did not request the coverage-floor cursor's before-page: $(cat "$d6b_log2" 2>/dev/null)"
fi

assert_no_dup_subset_events "$d6b_store" "d6 no-dup-subset: no inbox event's message-id set is a subset of another's"

# -----------------------------------------------------------------------
# 9c. Legacy fallback: floor absent but a prior capture event exists for
#     the chat (as it would for a chat whose first incremental capture
#     predates the D6 fix) — backfill must exclude every timestamp that
#     event already covered. Uses a sequenced stub: the chat's initial
#     (no-cursor) messages page differs between the incremental run (call
#     1) and the backfill run's no-floor no-cursor request (call 2+), since
#     both hit the exact same path.
# -----------------------------------------------------------------------
d6c_root="$D6_ROOT/9c-legacy-fallback"
d6c_data_root="$d6c_root/data-root"
d6c_data="$d6c_data_root/connectors/beeper-in"
d6c_store="$d6c_root/store"
mkdir -p "$d6c_store" "$d6c_data"
make_beeper_config "$d6c_data" "$d6c_store" "matrix"

d6c_seq_stub="$d6c_root/seq-stub.sh"
cat > "$d6c_seq_stub" <<'EOF'
#!/bin/sh
path="$1"
[ -n "${STUB_LOG:-}" ] && echo "$path" >> "$STUB_LOG"
case "$path" in
  /v1/info)
    cat "$STUB_INFO"
    exit 0
    ;;
  /v1/accounts)
    cat "$STUB_ACCOUNTS"
    exit 0
    ;;
  /v1/chats\?*)
    cat "$STUB_CHATS"
    exit 0
    ;;
esac
n=$(cat "$STUB_COUNTER")
n=$((n + 1))
echo "$n" > "$STUB_COUNTER"
if [ "$n" -eq 1 ]; then
  cat "$STUB_MSG_INCREMENTAL"
else
  cat "$STUB_MSG_LEGACY_MIXED"
fi
EOF
chmod +x "$d6c_seq_stub"

d6c_counter="$d6c_root/counter"
echo 0 > "$d6c_counter"

d6c_log="$d6c_root/stub-argv.log"
(
  export STUB_LOG="$d6c_log"
  export STUB_COUNTER="$d6c_counter"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_INCREMENTAL="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_LEGACY_MIXED="$d6_msgs_legacy_mixed"
  BEEPER_HTTP_STUB="$d6c_seq_stub" "$SWEEP_SCRIPT" --data-dir "$d6c_data"
) > "$d6c_root/stdout-incr.log" 2>"$d6c_root/stderr-incr.log"
d6c_incr_rc=$?
assert_eq "d6 legacy fallback: prior incremental run exits 0" "$d6c_incr_rc" "0"

# Simulate a chat whose first incremental capture predates the D6 fix:
# remove the just-written coverage-floor entry while leaving the inbox
# event (the legacy signal) in place.
rm -f "$d6c_data/coverage-floor.tsv"

d6c_bf_log="$d6c_root/stub-argv-backfill.log"
(
  export STUB_LOG="$d6c_bf_log"
  export STUB_COUNTER="$d6c_counter"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_INCREMENTAL="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_LEGACY_MIXED="$d6_msgs_legacy_mixed"
  BEEPER_HTTP_STUB="$d6c_seq_stub" "$SWEEP_SCRIPT" --data-dir "$d6c_data" --backfill
) > "$d6c_root/stdout-backfill.log" 2>"$d6c_root/stderr-backfill.log"
d6c_bf_rc=$?
assert_eq "d6 legacy fallback: backfill run (no floor) exits 0" "$d6c_bf_rc" "0"

if grep -rq 'msg-legacy-old-001' "$d6c_store"/inbox/*.md 2>/dev/null; then
  pass "d6 legacy fallback: message older than the legacy oldest-covered timestamp is captured"
else
  fail "d6 legacy fallback: expected genuinely-older legacy message not found in any inbox event"
fi

d6c_dup_count="$(grep -rl 'msg-sample-001' "$d6c_store"/inbox/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "d6 legacy fallback: already-captured message id appears only in the incremental run's own event, never re-captured by backfill" "$d6c_dup_count" "1"

# -----------------------------------------------------------------------
# 9c2. Null-timestamp poison guard: beeper_legacy_oldest_covered_ts must
#      reject a candidate floor that is the literal string "null" (or
#      anything not shaped like an ISO-8601 timestamp), not just an empty
#      one. An unguarded "null" floor sorts lexically higher than every
#      real ISO timestamp ('n' > '2'), so `.timestamp < $lm` would match
#      every covered message and backfill would re-capture the whole chat.
#      Exercised directly against the function (not via the full sweep)
#      for a deterministic, single-shot repro of the exact poisoned value.
# -----------------------------------------------------------------------
d6c2_store="$D6_ROOT/9c2-null-timestamp-guard/store"
mkdir -p "$d6c2_store/inbox"
d6c2_chat_id='!poison-chat:example.org'
cat > "$d6c2_store/inbox/poison-event.md" <<EOF
---
id: test-legacy-null-poison
---
{"chatID": "$d6c2_chat_id", "messages": [{"id": "msg-poison-1", "timestamp": "null"}]}
EOF

d6c2_out="$(beeper_legacy_oldest_covered_ts "$d6c2_store" "$d6c2_chat_id")"
d6c2_rc=$?
assert_eq "d6 null-timestamp guard: a chat whose only prior event has a literal-\"null\" timestamp yields no candidate floor (rc=1)" "$d6c2_rc" "1"
assert_eq "d6 null-timestamp guard: no poisoned \"null\" string is ever printed as the floor" "$d6c2_out" ""

# -----------------------------------------------------------------------
# 9d. History-clamped WARN: bridge history exhausted (hasMore false, no
#     oldestCursor) before reaching the resolved window start ->
#     `<chatID>=history-clamped@<oldest_ts>` appears in the backfill run's
#     runs.log WARN field.
# -----------------------------------------------------------------------
d6d_root="$D6_ROOT/9d-history-clamped"
d6d_data_root="$d6d_root/data-root"
d6d_data="$d6d_data_root/connectors/beeper-in"
d6d_store="$d6d_root/store"
mkdir -p "$d6d_store" "$d6d_data"
make_beeper_config "$d6d_data" "$d6d_store" "matrix"

(
  export STUB_LOG="$(mktemp)"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6d_data"
) > /dev/null 2>&1

d6d_log="$d6d_root/stub-argv-backfill.log"
(
  export STUB_LOG="$d6d_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$d6_msgs_older"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6d_data" --backfill
) > "$d6d_root/stdout.log" 2>"$d6d_root/stderr.log"
d6d_rc=$?
assert_eq "d6 history-clamped: backfill run exits 0" "$d6d_rc" "0"

d6d_runlog_last="$(tail -n1 "$d6d_data/runs.log" 2>/dev/null)"
if printf '%s' "$d6d_runlog_last" | grep -Eq 'history-clamped@2026-06-15T10:00:00\.000Z'; then
  pass "d6 history-clamped: runs.log WARN records history-clamped@<oldest_ts> for the exhausted chat"
else
  fail "d6 history-clamped: expected history-clamped@ warning not found in runs.log last line: [$d6d_runlog_last]"
fi

# -----------------------------------------------------------------------
# 9e. Incremental files byte-identical: cursors.tsv and last-sweep (the
#     incremental ledger) are byte-for-byte unchanged by a --backfill run
#     against the same data dir.
# -----------------------------------------------------------------------
d6e_root="$D6_ROOT/9e-incremental-untouched"
d6e_data_root="$d6e_root/data-root"
d6e_data="$d6e_data_root/connectors/beeper-in"
d6e_store="$d6e_root/store"
mkdir -p "$d6e_store" "$d6e_data"
make_beeper_config "$d6e_data" "$d6e_store" "matrix"

(
  export STUB_LOG="$(mktemp)"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6e_data"
) > /dev/null 2>&1

d6e_cursors_snapshot="$d6e_root/cursors.tsv.before"
d6e_lastsweep_snapshot="$d6e_root/last-sweep.before"
cp "$d6e_data/cursors.tsv" "$d6e_cursors_snapshot"
cp "$d6e_data/last-sweep" "$d6e_lastsweep_snapshot"

(
  export STUB_LOG="$(mktemp)"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$d6_chats_single"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$d6_msgs_older"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$d6e_data" --backfill
) > /dev/null 2>&1

if diff -q "$d6e_cursors_snapshot" "$d6e_data/cursors.tsv" >/dev/null 2>&1; then
  pass "d6 incremental untouched: cursors.tsv is byte-identical before/after a --backfill run"
else
  fail "d6 incremental untouched: cursors.tsv changed after a --backfill run — diff: $(diff "$d6e_cursors_snapshot" "$d6e_data/cursors.tsv" 2>&1 | tr '\n' ' ')"
fi

if diff -q "$d6e_lastsweep_snapshot" "$d6e_data/last-sweep" >/dev/null 2>&1; then
  pass "d6 incremental untouched: last-sweep is byte-identical before/after a --backfill run"
else
  fail "d6 incremental untouched: last-sweep changed after a --backfill run — diff: $(diff "$d6e_lastsweep_snapshot" "$d6e_data/last-sweep" 2>&1 | tr '\n' ' ')"
fi

fi # D6 SWEEP_SCRIPT / NORMALIZE_SCRIPT / RESOLVE_WINDOW_SCRIPT present

# =============================================================================
# 9. store_dir precedence (plan 40 dynamic sync routing): when config.json
#    has no store_dir, the sweep falls back to $SPOMNI_STORE_DIR, then to
#    <data-dir>/../../store (pwd -P). An explicit config store_dir always
#    wins over $SPOMNI_STORE_DIR. Same route_stub + fixture harness as
#    section 7, single-account single-chat single-message fixtures so each
#    run produces exactly one capture.
# =============================================================================

if [ ! -x "$SWEEP_SCRIPT" ] || [ ! -x "$NORMALIZE_SCRIPT" ]; then
  fail "store_dir precedence: beeper-sweep.sh or normalize-capture.sh not found/executable — skipping"
else

# make_beeper_config_no_store_dir <data_dir> <enabled_ids_space_sep> —
# same as make_beeper_config but omits store_dir entirely from config.json.
make_beeper_config_no_store_dir() {
  data_dir="$1"
  ids="$2"
  token="e2e-test-token"

  mkdir -p "$data_dir"

  ids_json="[]"
  if [ -n "$ids" ]; then
    ids_json="$(printf '%s\n' $ids | jq -R . | jq -sc .)"
  fi

  cat > "$data_dir/config.json" <<EOF
{
  "base_url": "http://127.0.0.1:23373",
  "enabled_account_ids": $ids_json,
  "max_chats_per_run": 50,
  "max_pages_per_chat": 10
}
EOF

  printf '%s\n' "$token" > "$data_dir/token"
}

SD_ROOT="$SANDBOX/store-dir-precedence"
mkdir -p "$SD_ROOT"

# --- (a) no config store_dir, no env -> defaults to <data-dir>/../../store
#     via the <root>/data/connectors/beeper-in + <root>/data/store layout. ---
sd_a_root="$SD_ROOT/a-default"
sd_a_data_root="$sd_a_root/data"
sd_a_data="$sd_a_data_root/connectors/beeper-in"
sd_a_default_store="$sd_a_data_root/store"
mkdir -p "$sd_a_default_store" "$sd_a_data"
make_beeper_config_no_store_dir "$sd_a_data" "matrix"

sd_a_log="$sd_a_root/stub-argv.log"
(
  export STUB_LOG="$sd_a_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  unset SPOMNI_STORE_DIR
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$sd_a_data"
) > "$sd_a_root/stdout.log" 2>"$sd_a_root/stderr.log"
sd_a_rc=$?

assert_eq "store_dir precedence (a) no config, no env: sweep exits 0" "$sd_a_rc" "0"

sd_a_inbox_count="$(find "$sd_a_default_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "store_dir precedence (a) no config, no env: capture lands in <data-dir>/../../store" "$sd_a_inbox_count" "2"

sd_a_runlog_last="$(tail -n1 "$sd_a_data/runs.log" 2>/dev/null)"
if printf '%s' "$sd_a_runlog_last" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ok chats=2 events=2 quarantined=0$'; then
  pass "store_dir precedence (a) no config, no env: runs.log logs ok"
else
  fail "store_dir precedence (a): unexpected runs.log last line: [$sd_a_runlog_last]"
fi

# --- (b) no config store_dir, SPOMNI_STORE_DIR set to another dir -> that
#     env dir wins over the default <data-dir>/../../store. ---
sd_b_root="$SD_ROOT/b-env"
sd_b_data_root="$sd_b_root/data"
sd_b_data="$sd_b_data_root/connectors/beeper-in"
sd_b_default_store="$sd_b_data_root/store"
sd_b_env_store="$sd_b_root/env-store"
mkdir -p "$sd_b_default_store" "$sd_b_env_store" "$sd_b_data"
make_beeper_config_no_store_dir "$sd_b_data" "matrix"

sd_b_log="$sd_b_root/stub-argv.log"
(
  export STUB_LOG="$sd_b_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  export SPOMNI_STORE_DIR="$sd_b_env_store"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$sd_b_data"
) > "$sd_b_root/stdout.log" 2>"$sd_b_root/stderr.log"
sd_b_rc=$?

assert_eq "store_dir precedence (b) SPOMNI_STORE_DIR set: sweep exits 0" "$sd_b_rc" "0"

sd_b_env_inbox_count="$(find "$sd_b_env_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "store_dir precedence (b) SPOMNI_STORE_DIR set: capture lands in the env store dir" "$sd_b_env_inbox_count" "2"

sd_b_default_inbox_count="$(find "$sd_b_default_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "store_dir precedence (b) SPOMNI_STORE_DIR set: default <data-dir>/../../store stays empty" "$sd_b_default_inbox_count" "0"

# --- (c) config store_dir set AND SPOMNI_STORE_DIR set -> config wins. ---
sd_c_root="$SD_ROOT/c-config-wins"
sd_c_data_root="$sd_c_root/data"
sd_c_data="$sd_c_data_root/connectors/beeper-in"
sd_c_config_store="$sd_c_root/config-store"
sd_c_env_store="$sd_c_root/env-store"
mkdir -p "$sd_c_config_store" "$sd_c_env_store" "$sd_c_data"
make_beeper_config "$sd_c_data" "$sd_c_config_store" "matrix"

sd_c_log="$sd_c_root/stub-argv.log"
(
  export STUB_LOG="$sd_c_log"
  export STUB_INFO="$info_body"
  export STUB_ACCOUNTS="$FIXTURES_DIR/accounts.json"
  export STUB_CHATS="$FIXTURES_DIR/chats-page.json"
  export STUB_MSG_FIRST="$FIXTURES_DIR/messages-page.json"
  export STUB_MSG_CURSOR="$FIXTURES_DIR/messages-empty.json"
  export SPOMNI_STORE_DIR="$sd_c_env_store"
  BEEPER_HTTP_STUB="$route_stub" "$SWEEP_SCRIPT" --data-dir "$sd_c_data"
) > "$sd_c_root/stdout.log" 2>"$sd_c_root/stderr.log"
sd_c_rc=$?

assert_eq "store_dir precedence (c) config + env both set: sweep exits 0" "$sd_c_rc" "0"

sd_c_config_inbox_count="$(find "$sd_c_config_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "store_dir precedence (c) config + env both set: capture lands in the config store dir" "$sd_c_config_inbox_count" "2"

sd_c_env_inbox_count="$(find "$sd_c_env_store/inbox" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -c .)"
assert_eq "store_dir precedence (c) config + env both set: env store dir stays empty (config wins)" "$sd_c_env_inbox_count" "0"

fi # store_dir precedence SWEEP_SCRIPT / NORMALIZE_SCRIPT present

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi

# --- E2E tests appended by unit S5 below ---
