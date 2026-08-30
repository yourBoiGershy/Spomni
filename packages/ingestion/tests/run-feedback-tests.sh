#!/usr/bin/env bash
# packages/ingestion/tests/run-feedback-tests.sh
#
# Asserts feedback-file.sh (the sole writer of the append-only feedback
# ledger, <store-dir>/signals/feedback.jsonl, plan 34 D1). Sections are
# added by sibling units — keep the `# --- part N: ... ---` headers so more
# can be appended without disturbing this one.
#
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

# --- part 1: feedback-file.sh ---

FEEDBACK_FILE="$REPO_ROOT/packages/ingestion/scripts/feedback-file.sh"

if [ ! -f "$FEEDBACK_FILE" ]; then
  echo "SKIP: $FEEDBACK_FILE not found — cannot run feedback ledger tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, feedback-file.sh missing"
  exit 1
fi

if [ ! -x "$FEEDBACK_FILE" ]; then
  fail "$FEEDBACK_FILE exists but is not executable"
fi

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found — cannot run feedback ledger tests."; echo ""; echo "SUMMARY: 0 passed, 0 failed, jq missing"; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- case: bad --type exits 2, nothing written ---
STORE1="$WORKDIR/store1"
out="$("$FEEDBACK_FILE" "$STORE1" --type bogus-type --target person:jane-doe --source session 2>&1)"
status=$?
if [ "$status" -eq 2 ]; then
  pass "bad --type exits 2"
else
  fail "bad --type expected exit 2, got $status ($out)"
fi
if [ -d "$STORE1/signals" ]; then
  fail "bad --type must not create signals/ dir"
else
  pass "bad --type creates no signals/ dir"
fi

# --- case: missing --target exits 2 ---
STORE2="$WORKDIR/store2"
"$FEEDBACK_FILE" "$STORE2" --type dismiss --source session >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  pass "missing --target exits 2"
else
  fail "missing --target expected exit 2, got $status"
fi

# --- case: bad --source exits 2 ---
STORE3="$WORKDIR/store3"
"$FEEDBACK_FILE" "$STORE3" --type dismiss --target person:jane-doe --source bogus >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  pass "bad --source exits 2"
else
  fail "bad --source expected exit 2, got $status"
fi

# --- case: bad target shape exits 2 ---
STORE4="$WORKDIR/store4"
"$FEEDBACK_FILE" "$STORE4" --type dismiss --target bogus --source session >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  pass "bad --target shape exits 2"
else
  fail "bad --target shape expected exit 2, got $status"
fi

# --- case: two calls append exactly 2 lines, first line untouched ---
STORE5="$WORKDIR/store5"
"$FEEDBACK_FILE" "$STORE5" --type dismiss --target person:jane-doe --source session --ts 2026-08-30T14:00:00Z >/dev/null 2>&1
status1=$?
if [ "$status1" -eq 0 ]; then
  pass "first call exits 0"
else
  fail "first call expected exit 0, got $status1"
fi
LEDGER5="$STORE5/signals/feedback.jsonl"
first_line_before="$(sed -n '1p' "$LEDGER5" 2>/dev/null)"

"$FEEDBACK_FILE" "$STORE5" --type snooze --target person:jane-doe --source auto --ts 2026-08-30T15:00:00Z >/dev/null 2>&1
status2=$?
if [ "$status2" -eq 0 ]; then
  pass "second call exits 0"
else
  fail "second call expected exit 0, got $status2"
fi

line_count="$(wc -l < "$LEDGER5" | tr -d ' ')"
if [ "$line_count" -eq 2 ]; then
  pass "two calls produce exactly 2 lines"
else
  fail "two calls expected 2 lines, got $line_count"
fi

first_line_after="$(sed -n '1p' "$LEDGER5" 2>/dev/null)"
if [ "$first_line_before" = "$first_line_after" ]; then
  pass "first line byte-identical after the second call"
else
  fail "first line changed after the second call"
fi

# --- case: --text round-trips embedded quotes, newline, unicode ---
STORE6="$WORKDIR/store6"
RAW_TEXT='she said "hi" there
héllo ✓'
"$FEEDBACK_FILE" "$STORE6" --type freeform --target person:jane-doe --source reply --text "$RAW_TEXT" >/dev/null 2>&1
status=$?
if [ "$status" -eq 0 ]; then
  pass "--text with quotes/newline/unicode exits 0"
else
  fail "--text with quotes/newline/unicode expected exit 0, got $status"
fi
LEDGER6="$STORE6/signals/feedback.jsonl"
got_text="$(jq -r '.text' "$LEDGER6" 2>/dev/null)"
if [ "$got_text" = "$RAW_TEXT" ]; then
  pass "--text round-trips verbatim (quotes, newline, unicode)"
else
  fail "--text round-trip mismatch: got [$got_text] want [$RAW_TEXT]"
fi

# --- case: mkdir -p signals/ happens on first write ---
STORE7="$WORKDIR/store7"
if [ -d "$STORE7/signals" ]; then
  fail "signals/ should not pre-exist for store7 fixture setup"
fi
"$FEEDBACK_FILE" "$STORE7" --type done --target signal:overdue --source auto >/dev/null 2>&1
if [ -d "$STORE7/signals" ]; then
  pass "mkdir -p signals/ happens on first write"
else
  fail "signals/ dir not created on first write"
fi

# --- case: exact line shape for the documented example ---
STORE8="$WORKDIR/store8"
"$FEEDBACK_FILE" "$STORE8" --type tier-correction --target person:jane-doe --source session \
  --from active --to close --text "she's basically family" --ts 2026-08-30T14:05:00Z >/dev/null 2>&1
LEDGER8="$STORE8/signals/feedback.jsonl"
EXPECTED='{"ts":"2026-08-30T14:05:00Z","type":"tier-correction","target":"person:jane-doe","from":"active","to":"close","reason":null,"text":"she'"'"'s basically family","channel":null,"source":"session"}'
got_line="$(sed -n '1p' "$LEDGER8" 2>/dev/null)"
if [ "$got_line" = "$EXPECTED" ]; then
  pass "documented example produces the exact expected line"
else
  fail "documented example line mismatch: got [$got_line] want [$EXPECTED]"
fi

# --- case: every ledger line parses with jq -e . ---
all_parse=1
for f in "$LEDGER5" "$LEDGER6" "$LEDGER8"; do
  [ -f "$f" ] || continue
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    if ! printf '%s' "$l" | jq -e . >/dev/null 2>&1; then
      all_parse=0
    fi
  done < "$f"
done
if [ "$all_parse" -eq 1 ]; then
  pass "every ledger line parses with jq -e ."
else
  fail "some ledger line failed to parse with jq -e ."
fi

# --- case: key order via jq -c keys_unsorted ---
EXPECTED_KEYS='["ts","type","target","from","to","reason","text","channel","source"]'
got_keys="$(sed -n '1p' "$LEDGER8" | jq -c 'keys_unsorted' 2>/dev/null)"
if [ "$got_keys" = "$EXPECTED_KEYS" ]; then
  pass "key order matches ts,type,target,from,to,reason,text,channel,source"
else
  fail "key order mismatch: got $got_keys want $EXPECTED_KEYS"
fi

# --- part 2: feedback-parse.sh ---
#
# Mission test: proves replies are applied and never dropped — every
# numbered reply in the user's own note-to-self chat resolves to exactly
# one applied lifecycle op (or a freeform ledger line if it can't be
# resolved), and a reply is never silently swallowed.

FEEDBACK_PARSE="$REPO_ROOT/packages/ingestion/scripts/feedback-parse.sh"
FEEDBACK_FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/feedback"

if [ ! -f "$FEEDBACK_PARSE" ]; then
  echo "SKIP: $FEEDBACK_PARSE not found — cannot run feedback-parse tests."
else

PARSE_WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "$PARSE_WORKDIR"' EXIT

EVENT_SEQ=1

# setup_store <name> — a fresh copy of the base fixture store under
# $PARSE_WORKDIR/<name>. Returns the path on stdout.
setup_store() {
  _dst="$PARSE_WORKDIR/$1"
  cp -R "$FEEDBACK_FIXTURES/base" "$_dst"
  printf '%s' "$_dst"
}

# one_msg_array <chat-id> <msg-id> <text> [<msg-id> <text> ...] — a JSON
# array of beeper-shaped message objects (capture-event 1.2.0 chat-message
# body, packages/core/contracts/capture-event.md), on stdout.
one_msg_array() {
  _chatid="$1"
  shift
  _acc="[]"
  while [ "$#" -ge 2 ]; do
    _mid="$1"
    _text="$2"
    shift 2
    _entry="$(jq -n --arg id "$_mid" --arg chatID "$_chatid" --arg text "$_text" \
      '{id:$id, chatID:$chatID, accountID:"matrix", senderID:"u", senderName:"me", timestamp:"2026-08-30T14:00:00Z", sortKey:$id, type:"TEXT", text:$text, isSender:true, attachments:[], linkedMessageID:null, reactions:[]}')"
    _acc="$(printf '%s' "$_acc" | jq --argjson e "$_entry" '. + [$e]')"
  done
  printf '%s' "$_acc"
}

# write_event <store> <chat-id> <messages-json-array> — writes one
# inbox/*.md chat-message capture event (1.2.0) with the given body; the
# filename stem is timestamp-ordered across calls so cursor sort order is
# deterministic. Prints the id (filename stem) on stdout.
write_event() {
  _store="$1"
  _chatid="$2"
  _messages="$3"
  _ts="$(printf '20260830T14%04dZ' "$EVENT_SEQ")"
  _id="${_ts}-beeper-in-matrix-$(printf '%04d' "$EVENT_SEQ")"
  EVENT_SEQ=$((EVENT_SEQ + 1))
  mkdir -p "$_store/inbox"
  _body="$(jq -n --arg chatID "$_chatid" --argjson messages "$_messages" \
    '{chatID:$chatID, accountID:"matrix", network:"matrix", title:"Note to self", chatType:"single", messages:$messages}')"
  {
    printf '%s\n' "---"
    printf 'schema_version: 1.2.0\n'
    printf 'id: %s\n' "$_id"
    printf 'source: beeper-in/matrix\n'
    printf 'captured_at: %s\n' "$_ts"
    printf 'type: chat-message\n'
    printf '%s\n' "---"
    printf '%s\n' "$_body"
  } > "$_store/inbox/${_id}.md"
  printf '%s' "$_id"
}

# field_value <file> <field> — first "<field>: <value>" line's value within
# the frontmatter block, trimmed.
field_value() {
  grep -m1 "^$2:" "$1" | sed -E "s/^$2:[[:space:]]*//"
}

# --- case: "1 done" applies + ledgers, idempotent rerun is a no-op ---
STORE_DONE="$(setup_store case-done)"
DATA_DONE="$PARSE_WORKDIR/case-done-data"
ev_done="$(write_event "$STORE_DONE" 1 "$(one_msg_array 1 m1 "1 done")")"
out_done1="$("$FEEDBACK_PARSE" "$STORE_DONE" --data-dir "$DATA_DONE" --today 2026-08-30 2>&1)"
status_done1=$?
if [ "$status_done1" -eq 0 ]; then pass "1 done: exits 0"; else fail "1 done: expected exit 0, got $status_done1 ($out_done1)"; fi
if [ "$(field_value "$STORE_DONE/wakeups/2026-08-20-jane-doe.md" status)" = "dismissed" ]; then
  pass "1 done: wakeup status -> dismissed"
else
  fail "1 done: wakeup status not dismissed"
fi
if [ "$(field_value "$STORE_DONE/wakeups/2026-08-20-jane-doe.md" dismiss-reason)" = "already-handled" ]; then
  pass "1 done: dismiss-reason -> already-handled"
else
  fail "1 done: dismiss-reason not already-handled"
fi
LEDGER_DONE="$STORE_DONE/signals/feedback.jsonl"
if jq -e 'select(.type == "done" and .target == "wakeup:2026-08-20-jane-doe")' "$LEDGER_DONE" >/dev/null 2>&1; then
  pass "1 done: ledgers a 'done' line"
else
  fail "1 done: no 'done' ledger line found"
fi
if jq -e 'select(.type == "dismiss" and .target == "wakeup:2026-08-20-jane-doe" and .reason == "already-handled")' "$LEDGER_DONE" >/dev/null 2>&1; then
  pass "1 done: dismiss hook also ledgers"
else
  fail "1 done: no dismiss hook ledger line found"
fi
applied_lines_before="$(wc -l < "$DATA_DONE/feedback-applied.log" | tr -d ' ')"
if [ "$applied_lines_before" -eq 1 ]; then
  pass "1 done: feedback-applied.log has exactly one row"
else
  fail "1 done: expected 1 applied-log row, got $applied_lines_before"
fi
ledger_lines_before="$(wc -l < "$LEDGER_DONE" | tr -d ' ')"
cursor_before="$(cat "$DATA_DONE/feedback-cursor" 2>/dev/null)"
if [ "$cursor_before" = "$ev_done" ]; then
  pass "1 done: cursor advanced to the processed event"
else
  fail "1 done: cursor expected '$ev_done', got '$cursor_before'"
fi
out_done2="$("$FEEDBACK_PARSE" "$STORE_DONE" --data-dir "$DATA_DONE" --today 2026-08-30 2>&1)"
status_done2=$?
if [ "$status_done2" -eq 0 ] && printf '%s' "$out_done2" | grep -q "nothing new"; then
  pass "1 done: idempotent rerun reports nothing new"
else
  fail "1 done: idempotent rerun expected 'nothing new', got '$out_done2' (exit $status_done2)"
fi
applied_lines_after="$(wc -l < "$DATA_DONE/feedback-applied.log" | tr -d ' ')"
ledger_lines_after="$(wc -l < "$LEDGER_DONE" | tr -d ' ')"
if [ "$applied_lines_after" -eq "$applied_lines_before" ] && [ "$ledger_lines_after" -eq "$ledger_lines_before" ]; then
  pass "1 done: idempotent rerun writes no new lines"
else
  fail "1 done: idempotent rerun changed line counts (applied $applied_lines_before->$applied_lines_after, ledger $ledger_lines_before->$ledger_lines_after)"
fi

# --- case: "1 snooze 2w" moves due +14d, snooze-count 1, reason 14d ---
STORE_SNOOZE="$(setup_store case-snooze)"
DATA_SNOOZE="$PARSE_WORKDIR/case-snooze-data"
write_event "$STORE_SNOOZE" 1 "$(one_msg_array 1 m1 "1 snooze 2w")" >/dev/null
out_snooze="$("$FEEDBACK_PARSE" "$STORE_SNOOZE" --data-dir "$DATA_SNOOZE" --today 2026-08-30 2>&1)"
status_snooze=$?
if [ "$status_snooze" -eq 0 ]; then pass "1 snooze 2w: exits 0"; else fail "1 snooze 2w: expected exit 0, got $status_snooze ($out_snooze)"; fi
if [ "$(field_value "$STORE_SNOOZE/wakeups/2026-08-20-jane-doe.md" due)" = "2026-09-13" ]; then
  pass "1 snooze 2w: due moved to 2026-09-13 (+14d)"
else
  fail "1 snooze 2w: due expected 2026-09-13, got $(field_value "$STORE_SNOOZE/wakeups/2026-08-20-jane-doe.md" due)"
fi
if [ "$(field_value "$STORE_SNOOZE/wakeups/2026-08-20-jane-doe.md" snooze-count)" = "1" ]; then
  pass "1 snooze 2w: snooze-count -> 1"
else
  fail "1 snooze 2w: snooze-count not 1"
fi
if jq -e 'select(.type == "snooze" and .target == "wakeup:2026-08-20-jane-doe" and .reason == "14d")' "$STORE_SNOOZE/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "1 snooze 2w: ledgers snooze with reason 14d"
else
  fail "1 snooze 2w: no matching snooze ledger line"
fi

# --- case: "2 skip" dismisses card 2 as not-now ---
STORE_SKIP="$(setup_store case-skip)"
DATA_SKIP="$PARSE_WORKDIR/case-skip-data"
write_event "$STORE_SKIP" 1 "$(one_msg_array 1 m1 "2 skip")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_SKIP" --data-dir "$DATA_SKIP" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_SKIP/wakeups/2026-08-21-sam-oyelaran.md" status)" = "dismissed" ] \
  && [ "$(field_value "$STORE_SKIP/wakeups/2026-08-21-sam-oyelaran.md" dismiss-reason)" = "not-now" ]; then
  pass "2 skip: card 2 dismissed with reason not-now"
else
  fail "2 skip: card 2 not dismissed as not-now"
fi

# --- case: "1 never birthday" opts out + no duplicate bullet on a second
# never-birthday reply against a different card ---
STORE_NEVER="$(setup_store case-never)"
DATA_NEVER="$PARSE_WORKDIR/case-never-data"
write_event "$STORE_NEVER" 1 "$(one_msg_array 1 m1 "1 never birthday" m2 "2 never birthday")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_NEVER" --data-dir "$DATA_NEVER" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_NEVER/wakeups/2026-08-20-jane-doe.md" dismiss-reason)" = "not-this-signal-type" ]; then
  pass "1 never birthday: card 1 dismissed as not-this-signal-type"
else
  fail "1 never birthday: card 1 not dismissed as not-this-signal-type"
fi
optout_count="$(grep -cF "birthday — all" "$STORE_NEVER/profile.md")"
if [ "$optout_count" -eq 1 ]; then
  pass "1 never birthday: exactly one 'birthday — all' bullet (deduped across the second never reply)"
else
  fail "1 never birthday: expected exactly one opt-out bullet, got $optout_count"
fi
if grep -qF -- "- **[stated-by-user]** birthday — all" "$STORE_NEVER/profile.md"; then
  pass "1 never birthday: opt-out bullet has the expected shape"
else
  fail "1 never birthday: opt-out bullet shape mismatch"
fi
if jq -e 'select(.type == "opt-out" and .target == "signal:birthday" and .to == "all")' "$STORE_NEVER/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "1 never birthday: ledgers opt-out signal:birthday -> all"
else
  fail "1 never birthday: no matching opt-out ledger line"
fi
mkdir -p "$STORE_NEVER/interactions"
# validate-store.sh's ## Notify allowance ships on the sibling chunk-33
# branch (profile.md 1.1.0) and is not yet merged here — make this
# assertion conditional so it goes live automatically once that branch
# merges, rather than failing on a cross-branch gap this unit doesn't own.
if grep -q '## Notify' "$REPO_ROOT/packages/core/scripts/validate-store.sh"; then
  validate_out="$(bash "$REPO_ROOT/packages/core/scripts/validate-store.sh" "$STORE_NEVER" 2>&1)"
  validate_status=$?
  if [ "$validate_status" -eq 0 ]; then
    pass "1 never birthday: validate-store.sh reports the resulting store clean"
  else
    fail "1 never birthday: validate-store.sh did not report clean (status $validate_status) — $validate_out"
  fi
else
  echo "SKIP: validate-store lacks ## Notify (plan 33 not merged yet)"
fi

# --- case: "2 not-them" dismisses card 2 as not-this-person ---
STORE_NOTTHEM="$(setup_store case-not-them)"
DATA_NOTTHEM="$PARSE_WORKDIR/case-not-them-data"
write_event "$STORE_NOTTHEM" 1 "$(one_msg_array 1 m1 "2 not-them")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_NOTTHEM" --data-dir "$DATA_NOTTHEM" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_NOTTHEM/wakeups/2026-08-21-sam-oyelaran.md" dismiss-reason)" = "not-this-person" ]; then
  pass "2 not-them: card 2 dismissed as not-this-person"
else
  fail "2 not-them: card 2 not dismissed as not-this-person"
fi

# --- case: "1 wrong-tier close <text>" corrects the person's tier ---
STORE_TIER="$(setup_store case-wrong-tier)"
DATA_TIER="$PARSE_WORKDIR/case-wrong-tier-data"
write_event "$STORE_TIER" 1 "$(one_msg_array 1 m1 "1 wrong-tier close she's basically family now")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_TIER" --data-dir "$DATA_TIER" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_TIER/people/jane-doe.md" tier)" = "close" ]; then
  pass "1 wrong-tier close: person tier -> close"
else
  fail "1 wrong-tier close: tier expected close, got $(field_value "$STORE_TIER/people/jane-doe.md" tier)"
fi
if [ "$(field_value "$STORE_TIER/people/jane-doe.md" tier_source)" = "stated-by-user" ]; then
  pass "1 wrong-tier close: tier_source -> stated-by-user"
else
  fail "1 wrong-tier close: tier_source not stated-by-user"
fi
if jq -e 'select(.type == "tier-correction" and .target == "person:jane-doe" and .from == "active" and .to == "close" and .text == "she'"'"'s basically family now")' "$STORE_TIER/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "1 wrong-tier close: ledgers tier-correction with text"
else
  fail "1 wrong-tier close: no matching tier-correction ledger line"
fi

# --- case: "1 wrong-tier bogus" (unrecognized tier) falls through to freeform ---
STORE_BOGUS="$(setup_store case-wrong-tier-bogus)"
DATA_BOGUS="$PARSE_WORKDIR/case-wrong-tier-bogus-data"
write_event "$STORE_BOGUS" 1 "$(one_msg_array 1 m1 "1 wrong-tier bogus")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_BOGUS" --data-dir "$DATA_BOGUS" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_BOGUS/people/jane-doe.md" tier)" = "active" ]; then
  pass "1 wrong-tier bogus: person tier untouched"
else
  fail "1 wrong-tier bogus: person tier was modified"
fi
if jq -e 'select(.type == "freeform" and .target == "wakeup:2026-08-20-jane-doe" and .text == "1 wrong-tier bogus")' "$STORE_BOGUS/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "1 wrong-tier bogus: ledgers freeform against wakeup:<id>"
else
  fail "1 wrong-tier bogus: no matching freeform ledger line"
fi

# --- case: "7 done" (n > entries.length) falls through to freeform target model ---
STORE_OOR="$(setup_store case-out-of-range)"
DATA_OOR="$PARSE_WORKDIR/case-out-of-range-data"
write_event "$STORE_OOR" 1 "$(one_msg_array 1 m1 "7 done")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_OOR" --data-dir "$DATA_OOR" --today 2026-08-30 >/dev/null 2>&1
if jq -e 'select(.type == "freeform" and .target == "model" and .text == "7 done")' "$STORE_OOR/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "7 done: n > entries.length -> freeform target model"
else
  fail "7 done: expected freeform target model ledger line"
fi

# --- case: multi-line message (two grammar lines in one capture event) both apply ---
STORE_MULTI="$(setup_store case-multi)"
DATA_MULTI="$PARSE_WORKDIR/case-multi-data"
write_event "$STORE_MULTI" 1 "$(one_msg_array 1 m1 "1 done" m2 "2 skip")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_MULTI" --data-dir "$DATA_MULTI" --today 2026-08-30 >/dev/null 2>&1
if [ "$(field_value "$STORE_MULTI/wakeups/2026-08-20-jane-doe.md" status)" = "dismissed" ] \
  && [ "$(field_value "$STORE_MULTI/wakeups/2026-08-21-sam-oyelaran.md" status)" = "dismissed" ]; then
  pass "multi-line message: both grammar lines applied"
else
  fail "multi-line message: not both cards dismissed"
fi
multi_applied_lines="$(wc -l < "$DATA_MULTI/feedback-applied.log" | tr -d ' ')"
if [ "$multi_applied_lines" -eq 2 ]; then
  pass "multi-line message: feedback-applied.log has 2 rows"
else
  fail "multi-line message: expected 2 applied-log rows, got $multi_applied_lines"
fi

# --- case: unmatched verb "1 hello there" -> freeform target wakeup:<id>, text verbatim ---
STORE_UNMATCHED="$(setup_store case-unmatched)"
DATA_UNMATCHED="$PARSE_WORKDIR/case-unmatched-data"
write_event "$STORE_UNMATCHED" 1 "$(one_msg_array 1 m1 "1 hello there")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_UNMATCHED" --data-dir "$DATA_UNMATCHED" --today 2026-08-30 >/dev/null 2>&1
if jq -e 'select(.type == "freeform" and .target == "wakeup:2026-08-20-jane-doe" and .text == "1 hello there")' "$STORE_UNMATCHED/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "unmatched verb: freeform target wakeup:<id>, text verbatim"
else
  fail "unmatched verb: no matching freeform ledger line"
fi

# --- case: event from a non-notify chatID is ignored (cursor still advances) ---
STORE_OTHERCHAT="$(setup_store case-other-chat)"
DATA_OTHERCHAT="$PARSE_WORKDIR/case-other-chat-data"
ev_other="$(write_event "$STORE_OTHERCHAT" 2 "$(one_msg_array 2 m1 "1 done")")"
out_other="$("$FEEDBACK_PARSE" "$STORE_OTHERCHAT" --data-dir "$DATA_OTHERCHAT" --today 2026-08-30 2>&1)"
status_other=$?
if [ "$status_other" -eq 0 ]; then pass "chatID 2 (not notify chat): exits 0"; else fail "chatID 2: expected exit 0, got $status_other"; fi
if [ "$(field_value "$STORE_OTHERCHAT/wakeups/2026-08-20-jane-doe.md" status)" = "fired" ]; then
  pass "chatID 2: notify-chat card untouched"
else
  fail "chatID 2: card was touched despite chat-id mismatch"
fi
if [ ! -f "$STORE_OTHERCHAT/signals/feedback.jsonl" ]; then
  pass "chatID 2: no ledger writes at all"
else
  fail "chatID 2: unexpected ledger writes"
fi
if [ "$(cat "$DATA_OTHERCHAT/feedback-cursor" 2>/dev/null)" = "$ev_other" ]; then
  pass "chatID 2: cursor still advances past the ignored event"
else
  fail "chatID 2: cursor did not advance"
fi

# --- case: no delivered.log -> every line freeform target model, exit 0 ---
STORE_NODELIVERED="$(setup_store case-no-delivered)"
DATA_NODELIVERED="$PARSE_WORKDIR/case-no-delivered-data"
rm -rf "$STORE_NODELIVERED/outbox"
write_event "$STORE_NODELIVERED" 1 "$(one_msg_array 1 m1 "1 done")" >/dev/null
out_nodelivered="$("$FEEDBACK_PARSE" "$STORE_NODELIVERED" --data-dir "$DATA_NODELIVERED" --today 2026-08-30 2>&1)"
status_nodelivered=$?
if [ "$status_nodelivered" -eq 0 ]; then pass "no delivered.log: exits 0"; else fail "no delivered.log: expected exit 0, got $status_nodelivered"; fi
if [ "$(field_value "$STORE_NODELIVERED/wakeups/2026-08-20-jane-doe.md" status)" = "fired" ]; then
  pass "no delivered.log: card untouched (no card map to resolve against)"
else
  fail "no delivered.log: card was modified despite no card map"
fi
if jq -e 'select(.type == "freeform" and .target == "model" and .text == "1 done")' "$STORE_NODELIVERED/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "no delivered.log: ledgers freeform target model"
else
  fail "no delivered.log: no matching freeform ledger line"
fi

# --- case: no ## Notify chat configured -> exit 0, nothing touched ---
STORE_NONOTIFY="$(setup_store case-no-notify)"
DATA_NONOTIFY="$PARSE_WORKDIR/case-no-notify-data"
cp -f "$FEEDBACK_FIXTURES/profile-no-notify.md" "$STORE_NONOTIFY/profile.md"
out_nonotify="$("$FEEDBACK_PARSE" "$STORE_NONOTIFY" --data-dir "$DATA_NONOTIFY" --today 2026-08-30 2>&1)"
status_nonotify=$?
if [ "$status_nonotify" -eq 0 ] && printf '%s' "$out_nonotify" | grep -q "no notify chat configured"; then
  pass "no ## Notify: exits 0 with 'no notify chat configured'"
else
  fail "no ## Notify: expected exit 0 and 'no notify chat configured', got '$out_nonotify' (exit $status_nonotify)"
fi
if [ ! -f "$DATA_NONOTIFY/feedback-cursor" ]; then
  pass "no ## Notify: no cursor written"
else
  fail "no ## Notify: cursor was written despite no notify chat"
fi

# --- case: real core profile template + a ## Notify section whose HTML
# comment (mirroring every other section's inline "e.g." comment style)
# itself contains the literal substring "beeper_chat_id:" before the real
# bullet — the resolver must skip the comment and match only the real
# bullet line. Uses packages/core/templates/profile.md verbatim as the
# base, per the contract's template, comments intact. ---
STORE_TEMPLATE="$(setup_store case-template-notify)"
DATA_TEMPLATE="$PARSE_WORKDIR/case-template-notify-data"
{
  cat "$REPO_ROOT/packages/core/templates/profile.md"
  cat <<'NOTIFY_EOF'

## Notify

<!-- Delivery channel + notify settings (plan 33). Bullet grammar: "- **[stated-by-user]** beeper_chat_id: <id> (<YYYY-MM-DD>)" -->

- **[stated-by-user]** channel: beeper-self
- **[stated-by-user]** beeper_chat_id: 1 (2026-08-30)
- **[stated-by-user]** quiet_hours: 22:00-08:00
NOTIFY_EOF
} > "$STORE_TEMPLATE/profile.md"
write_event "$STORE_TEMPLATE" 1 "$(one_msg_array 1 m1 "1 skip")" >/dev/null
out_template="$("$FEEDBACK_PARSE" "$STORE_TEMPLATE" --data-dir "$DATA_TEMPLATE" --today 2026-08-30 2>&1)"
status_template=$?
if [ "$status_template" -eq 0 ]; then
  pass "template ## Notify (comment trap): exits 0"
else
  fail "template ## Notify (comment trap): expected exit 0, got $status_template ($out_template)"
fi
if [ "$(field_value "$STORE_TEMPLATE/wakeups/2026-08-20-jane-doe.md" status)" = "dismissed" ] \
  && [ "$(field_value "$STORE_TEMPLATE/wakeups/2026-08-20-jane-doe.md" dismiss-reason)" = "not-now" ]; then
  pass "template ## Notify (comment trap): resolved chat id 1 despite the comment line, card 1 dismissed not-now"
else
  fail "template ## Notify (comment trap): reply was not applied — resolver likely matched the HTML comment instead of the real bullet"
fi

# --- case: "1 draft mention the Tokyo race" -> no draft available for
# entry 1 (batch fixture has draft: null), Note line carries the free
# text, ledgers draft-request. Mission test: draft served only on
# request, never invented. ---
STORE_DRAFT1="$(setup_store case-draft-1)"
DATA_DRAFT1="$PARSE_WORKDIR/case-draft-1-data"
write_event "$STORE_DRAFT1" 1 "$(one_msg_array 1 m1 "1 draft mention the Tokyo race")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_DRAFT1" --data-dir "$DATA_DRAFT1" --today 2026-08-30 >/dev/null 2>&1
DRAFT1_FILE="$STORE_DRAFT1/outbox/drafts/20260830T120000Z-batch-1-draft.txt"
EXPECTED_DRAFT1='Draft (unsent):
no draft available for 1
Note: mention the Tokyo race'
if [ -f "$DRAFT1_FILE" ] && [ "$(cat "$DRAFT1_FILE")" = "$EXPECTED_DRAFT1" ]; then
  pass "1 draft <text>: draft file has no-draft-available + Note line"
else
  fail "1 draft <text>: draft file mismatch, got [$(cat "$DRAFT1_FILE" 2>/dev/null)] want [$EXPECTED_DRAFT1]"
fi
if jq -e 'select(.type == "draft-request" and .target == "wakeup:2026-08-20-jane-doe" and .text == "mention the Tokyo race" and .source == "reply")' "$STORE_DRAFT1/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "1 draft <text>: ledgers draft-request with text and source reply"
else
  fail "1 draft <text>: no matching draft-request ledger line"
fi

# --- case: "2 draft" -> entry 2's batch draft field served verbatim, no
# Note line (no free text supplied) ---
STORE_DRAFT2="$(setup_store case-draft-2)"
DATA_DRAFT2="$PARSE_WORKDIR/case-draft-2-data"
BATCH_DRAFT2="$STORE_DRAFT2/wakeups/fired/20260830T120000Z-batch.json"
jq '.entries[1].draft = "Hey Sam — congrats on the move!"' "$BATCH_DRAFT2" > "$BATCH_DRAFT2.tmp" && mv "$BATCH_DRAFT2.tmp" "$BATCH_DRAFT2"
write_event "$STORE_DRAFT2" 1 "$(one_msg_array 1 m1 "2 draft")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_DRAFT2" --data-dir "$DATA_DRAFT2" --today 2026-08-30 >/dev/null 2>&1
DRAFT2_FILE="$STORE_DRAFT2/outbox/drafts/20260830T120000Z-batch-2-draft.txt"
EXPECTED_DRAFT2='Draft (unsent):
Hey Sam — congrats on the move!'
if [ -f "$DRAFT2_FILE" ] && [ "$(cat "$DRAFT2_FILE")" = "$EXPECTED_DRAFT2" ]; then
  pass "2 draft: draft file serves the batch entry's draft verbatim, no Note line"
else
  fail "2 draft: draft file mismatch, got [$(cat "$DRAFT2_FILE" 2>/dev/null)] want [$EXPECTED_DRAFT2]"
fi

# --- case: "1 draft" re-request after the original draft file was already
# delivered -> a new timestamp-suffixed sibling is written, original
# untouched ---
STORE_DRAFT3="$(setup_store case-draft-3)"
DATA_DRAFT3="$PARSE_WORKDIR/case-draft-3-data"
DRAFT3_ORIG="$STORE_DRAFT3/outbox/drafts/20260830T120000Z-batch-1-draft.txt"
mkdir -p "$STORE_DRAFT3/outbox/drafts"
printf 'Draft (unsent):\nno draft available for 1\n' > "$DRAFT3_ORIG"
printf '%s\tnone\t2026-08-30T13:00:00Z\tm0\n' "20260830T120000Z-batch-1-draft.txt" >> "$STORE_DRAFT3/outbox/delivered.log"
orig_before="$(cat "$DRAFT3_ORIG")"
write_event "$STORE_DRAFT3" 1 "$(one_msg_array 1 m1 "1 draft")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_DRAFT3" --data-dir "$DATA_DRAFT3" --today 2026-08-30 >/dev/null 2>&1
sibling_count="$(find "$STORE_DRAFT3/outbox/drafts" -name '20260830T120000Z-batch-1-draft-*.txt' | wc -l | tr -d ' ')"
if [ "$sibling_count" -eq 1 ]; then
  pass "1 draft re-request: a new timestamp-suffixed sibling file is written"
else
  fail "1 draft re-request: expected 1 sibling draft file, got $sibling_count"
fi
if [ "$(cat "$DRAFT3_ORIG")" = "$orig_before" ]; then
  pass "1 draft re-request: original delivered draft file is untouched"
else
  fail "1 draft re-request: original draft file was modified"
fi

# --- case: "9 draft" (n > entries) falls through to freeform target model,
# no draft file written ---
STORE_DRAFT_OOR="$(setup_store case-draft-out-of-range)"
DATA_DRAFT_OOR="$PARSE_WORKDIR/case-draft-out-of-range-data"
write_event "$STORE_DRAFT_OOR" 1 "$(one_msg_array 1 m1 "9 draft")" >/dev/null
"$FEEDBACK_PARSE" "$STORE_DRAFT_OOR" --data-dir "$DATA_DRAFT_OOR" --today 2026-08-30 >/dev/null 2>&1
if jq -e 'select(.type == "freeform" and .target == "model" and .text == "9 draft")' "$STORE_DRAFT_OOR/signals/feedback.jsonl" >/dev/null 2>&1; then
  pass "9 draft: n > entries.length -> freeform target model"
else
  fail "9 draft: expected freeform target model ledger line"
fi
if [ ! -d "$STORE_DRAFT_OOR/outbox/drafts" ]; then
  pass "9 draft: no draft file written"
else
  fail "9 draft: unexpected outbox/drafts/ dir created"
fi

fi # FEEDBACK_PARSE exists

# --- case: feedback-file.sh --type draft-request is accepted ---
STORE_DRAFT_TYPE="$WORKDIR/store-draft-type"
"$FEEDBACK_FILE" "$STORE_DRAFT_TYPE" --type draft-request --target wakeup:2026-08-20-jane-doe --source reply >/dev/null 2>&1
status_draft_type=$?
if [ "$status_draft_type" -eq 0 ]; then
  pass "--type draft-request is accepted (exit 0)"
else
  fail "--type draft-request expected exit 0, got $status_draft_type"
fi

# --- part 3: feedback-recent.sh + feedback-to-evals.sh ---
#
# Mission test: guards that corrections reach prompts (feedback-recent.sh's
# render feeds every judgment prompt's input 2b) and become regression
# tests (feedback-to-evals.sh turns a correction into a T3 case that
# proves it sticks) — a correction the user makes once must never need
# re-explaining.

FEEDBACK_RECENT="$REPO_ROOT/packages/ingestion/scripts/feedback-recent.sh"
FEEDBACK_TO_EVALS="$REPO_ROOT/packages/ingestion/scripts/feedback-to-evals.sh"

# === feedback-recent.sh ===

if [ ! -f "$FEEDBACK_RECENT" ]; then
  echo "SKIP: $FEEDBACK_RECENT not found — cannot run feedback-recent tests."
else

RECENT_WORKDIR="$(mktemp -d)"
mkdir -p "$RECENT_WORKDIR/store/signals"
LEDGER_RECENT="$RECENT_WORKDIR/store/signals/feedback.jsonl"

jq -n -c '{ts:"2026-08-25T09:00:00Z", type:"kind-correction", target:"person:bob-cpa", from:null, to:"transactional", reason:null, text:null, channel:null, source:"session"}' >> "$LEDGER_RECENT"
jq -n -c '{ts:"2026-08-26T09:00:00Z", type:"kind-correction", target:"person:sam-oyelaran", from:"friend", to:"colleague", reason:null, text:"just a coworker", channel:null, source:"session"}' >> "$LEDGER_RECENT"
jq -n -c '{ts:"2026-08-27T09:00:00Z", type:"tier-correction", target:"person:jane-doe", from:"active", to:"close", reason:null, text:"she'"'"'s basically family", channel:null, source:"session"}' >> "$LEDGER_RECENT"
jq -n -c '{ts:"2026-08-28T09:00:00Z", type:"draft-edit", target:"person:jane-doe", from:null, to:null, reason:null, text:"tightened the opener", channel:null, source:"session"}' >> "$LEDGER_RECENT"

# --- case: default (--kind corrections) golden render, newest first ---
EXPECTED_RECENT_DEFAULT='## Recent corrections
- 2026-08-27 person:jane-doe — judge said tier=active, user said tier=close, words: "she'"'"'s basically family"
- 2026-08-26 person:sam-oyelaran — judge said kind=friend, user said kind=colleague, words: "just a coworker"
- 2026-08-25 person:bob-cpa — judge said kind=(none), user said kind=transactional'
got_recent_default="$("$FEEDBACK_RECENT" "$RECENT_WORKDIR/store")"
status_recent_default=$?
if [ "$status_recent_default" -eq 0 ] && [ "$got_recent_default" = "$EXPECTED_RECENT_DEFAULT" ]; then
  pass "feedback-recent: default golden render matches byte-for-byte"
else
  fail "feedback-recent: default golden render mismatch (exit $status_recent_default): got [$got_recent_default] want [$EXPECTED_RECENT_DEFAULT]"
fi

# --- case: --n 2 caps to the newest 2 ---
EXPECTED_RECENT_N2='## Recent corrections
- 2026-08-27 person:jane-doe — judge said tier=active, user said tier=close, words: "she'"'"'s basically family"
- 2026-08-26 person:sam-oyelaran — judge said kind=friend, user said kind=colleague, words: "just a coworker"'
got_recent_n2="$("$FEEDBACK_RECENT" "$RECENT_WORKDIR/store" --n 2)"
if [ "$got_recent_n2" = "$EXPECTED_RECENT_N2" ]; then
  pass "feedback-recent: --n 2 caps to newest 2"
else
  fail "feedback-recent: --n 2 mismatch: got [$got_recent_n2] want [$EXPECTED_RECENT_N2]"
fi

# --- case: --person filters to that person's corrections only ---
EXPECTED_RECENT_PERSON='## Recent corrections
- 2026-08-27 person:jane-doe — judge said tier=active, user said tier=close, words: "she'"'"'s basically family"'
got_recent_person="$("$FEEDBACK_RECENT" "$RECENT_WORKDIR/store" --person jane-doe)"
if [ "$got_recent_person" = "$EXPECTED_RECENT_PERSON" ]; then
  pass "feedback-recent: --person jane-doe filters to jane-doe's correction only"
else
  fail "feedback-recent: --person filter mismatch: got [$got_recent_person] want [$EXPECTED_RECENT_PERSON]"
fi

# --- case: --kind all shows both headings, corrections first ---
EXPECTED_RECENT_ALL='## Recent corrections
- 2026-08-27 person:jane-doe — judge said tier=active, user said tier=close, words: "she'"'"'s basically family"
- 2026-08-26 person:sam-oyelaran — judge said kind=friend, user said kind=colleague, words: "just a coworker"
- 2026-08-25 person:bob-cpa — judge said kind=(none), user said kind=transactional

## Recent draft edits
- 2026-08-28 person:jane-doe — tightened the opener'
got_recent_all="$("$FEEDBACK_RECENT" "$RECENT_WORKDIR/store" --kind all)"
if [ "$got_recent_all" = "$EXPECTED_RECENT_ALL" ]; then
  pass "feedback-recent: --kind all renders both headings, corrections first"
else
  fail "feedback-recent: --kind all mismatch: got [$got_recent_all] want [$EXPECTED_RECENT_ALL]"
fi

# --- case: missing ledger -> heading + _none yet_, exit 0 ---
EMPTY_RECENT_STORE="$RECENT_WORKDIR/empty-store"
mkdir -p "$EMPTY_RECENT_STORE"
EXPECTED_RECENT_NONE='## Recent corrections
_none yet_'
got_recent_none="$("$FEEDBACK_RECENT" "$EMPTY_RECENT_STORE")"
status_recent_none=$?
if [ "$status_recent_none" -eq 0 ] && [ "$got_recent_none" = "$EXPECTED_RECENT_NONE" ]; then
  pass "feedback-recent: missing ledger -> heading + _none yet_, exit 0"
else
  fail "feedback-recent: missing ledger mismatch (exit $status_recent_none): got [$got_recent_none] want [$EXPECTED_RECENT_NONE]"
fi

rm -rf "$RECENT_WORKDIR"

fi # FEEDBACK_RECENT exists

# === feedback-to-evals.sh ===

if [ ! -f "$FEEDBACK_TO_EVALS" ]; then
  echo "SKIP: $FEEDBACK_TO_EVALS not found — cannot run feedback-to-evals tests."
else

FEEDBACK_EVALS_FIXTURE="$REPO_ROOT/packages/ingestion/tests/fixtures/feedback-evals/store"
EVALS_WORKDIR="$(mktemp -d)"
STORE_EVALS="$EVALS_WORKDIR/store"
cp -R "$FEEDBACK_EVALS_FIXTURE" "$STORE_EVALS"
DATA_EVALS="$EVALS_WORKDIR/data"

out_evals1="$("$FEEDBACK_TO_EVALS" "$STORE_EVALS" --data-dir "$DATA_EVALS" 2>&1)"
status_evals1=$?
if [ "$status_evals1" -eq 0 ] && printf '%s' "$out_evals1" | grep -q "cases=1"; then
  pass "feedback-to-evals: first run exits 0, cases=1"
else
  fail "feedback-to-evals: first run expected exit 0 and cases=1, got '$out_evals1' (exit $status_evals1)"
fi

CASE_DIR="$DATA_EVALS/evals/feedback/cases/jane-doe-tier-correction"
if [ -d "$CASE_DIR/before" ] && [ -f "$CASE_DIR/prompt.md" ] \
  && [ -f "$CASE_DIR/graders/01-stated-holds.sh" ] && [ -d "$CASE_DIR/expected" ]; then
  pass "feedback-to-evals: case dir has all four parts (before/, prompt.md, graders/, expected/)"
else
  fail "feedback-to-evals: case dir missing one of the four parts"
fi

SUITE_EVALS="$DATA_EVALS/evals/feedback/suite.txt"
suite_case_lines="$(grep -vc '^#' "$SUITE_EVALS" 2>/dev/null)"
if [ "$suite_case_lines" = "1" ] && grep -qF "$CASE_DIR" "$SUITE_EVALS"; then
  pass "feedback-to-evals: suite.txt has exactly one case line, pointing at the case dir"
else
  fail "feedback-to-evals: suite.txt expected exactly one case line for $CASE_DIR, got $suite_case_lines lines"
fi

# --- grader: hand-derived, exit 0 when tier: close + tier_source: stated-by-user ---
GRADER_EVALS="$CASE_DIR/graders/01-stated-holds.sh"
mkdir -p "$EVALS_WORKDIR/grader-pass/people"
cp "$CASE_DIR/before/people/jane-doe.md" "$EVALS_WORKDIR/grader-pass/people/jane-doe.md"
"$GRADER_EVALS" "$EVALS_WORKDIR/grader-pass" >/dev/null 2>&1
status_grader_pass=$?
if [ "$status_grader_pass" -eq 0 ]; then
  pass "feedback-to-evals: grader exits 0 against tier: close + tier_source: stated-by-user"
else
  fail "feedback-to-evals: grader expected exit 0, got $status_grader_pass"
fi

mkdir -p "$EVALS_WORKDIR/grader-fail/people"
sed 's/^tier: close$/tier: active/' "$CASE_DIR/before/people/jane-doe.md" > "$EVALS_WORKDIR/grader-fail/people/jane-doe.md"
"$GRADER_EVALS" "$EVALS_WORKDIR/grader-fail" >/dev/null 2>&1
status_grader_fail=$?
if [ "$status_grader_fail" -ne 0 ]; then
  pass "feedback-to-evals: grader exits non-zero against tier: active"
else
  fail "feedback-to-evals: grader expected non-zero exit against tier: active, got 0"
fi

# --- idempotent rerun: byte-identical ---
cp -R "$DATA_EVALS/evals/feedback" "$EVALS_WORKDIR/feedback-snapshot1"
out_evals2="$("$FEEDBACK_TO_EVALS" "$STORE_EVALS" --data-dir "$DATA_EVALS" 2>&1)"
status_evals2=$?
diff_evals="$(diff -r "$EVALS_WORKDIR/feedback-snapshot1" "$DATA_EVALS/evals/feedback" 2>&1)"
if [ "$status_evals2" -eq 0 ] && printf '%s' "$out_evals2" | grep -q "cases=1" && [ -z "$diff_evals" ]; then
  pass "feedback-to-evals: idempotent rerun is byte-identical"
else
  fail "feedback-to-evals: idempotent rerun changed output (exit $status_evals2, out '$out_evals2', diff: $diff_evals)"
fi

# --- append a newer tier-correction for jane-doe (to=dormant): regenerated
#     grader asserts dormant, still exactly one case (latest wins) ---
jq -n -c '{ts:"2026-08-25T10:00:00Z", type:"tier-correction", target:"person:jane-doe", from:"close", to:"dormant", reason:null, text:"drifted apart", channel:null, source:"session"}' >> "$STORE_EVALS/signals/feedback.jsonl"
out_evals3="$("$FEEDBACK_TO_EVALS" "$STORE_EVALS" --data-dir "$DATA_EVALS" 2>&1)"
status_evals3=$?
if [ "$status_evals3" -eq 0 ] && printf '%s' "$out_evals3" | grep -q "cases=1"; then
  pass "feedback-to-evals: newer correction regenerates, still exactly one case"
else
  fail "feedback-to-evals: newer correction expected exit 0 and cases=1, got '$out_evals3' (exit $status_evals3)"
fi
case_dir_count="$(find "$DATA_EVALS/evals/feedback/cases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$case_dir_count" = "1" ]; then
  pass "feedback-to-evals: exactly one case dir on disk after the newer correction"
else
  fail "feedback-to-evals: expected 1 case dir, got $case_dir_count"
fi
if grep -qF "tier: dormant" "$CASE_DIR/graders/01-stated-holds.sh" && grep -qF "tier_source: stated-by-user" "$CASE_DIR/graders/01-stated-holds.sh"; then
  pass "feedback-to-evals: regenerated grader asserts tier: dormant (tier_source: stated-by-user)"
else
  fail "feedback-to-evals: regenerated grader does not assert dormant"
fi

rm -rf "$EVALS_WORKDIR"

fi # FEEDBACK_TO_EVALS exists

# --- part N: (reserved for sibling units) ---

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
