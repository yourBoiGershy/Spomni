#!/usr/bin/env bash
# packages/ingestion/tests/run-thread-tests.sh
#
# Regression-locks packages/ingestion/scripts/summarize-thread.sh (plan 32
# U1) and packages/ingestion/scripts/file-thread.sh (plan 32 U2/D2/D3)
# against packages/ingestion/tests/fixtures/thread/, per plan 32 unit 2/3.
# Same style as run-structured-tests.sh: numbered assertions via
# pass()/fail(), a SUMMARY line, non-zero exit on any failure. bash 3.2
# portable (no associative arrays, no mapfile). No model calls anywhere in
# this suite: the summarize-thread.sh section exercises RA_THREAD_DRY_RUN=1
# / RA_THREAD_PARSE_TEST=<file> / a stubbed `claude` on PATH; file-thread.sh
# never calls a model at all (deterministic writer, summary JSON is an
# input).
#
# NOTE for a future worker adding more cases to either script: keep them
# under the matching "# --- <script>.sh ---" section header, sharing
# PASS_COUNT/FAIL_COUNT/pass()/fail() and the final SUMMARY line.
#
# Fixtures (packages/ingestion/tests/fixtures/thread/), all synthetic PII
# (invented names, example.test addresses, a fake Matrix-style senderID —
# nothing from any real store):
#
#   events/chat-fixture.md — a capture-event 1.2.0 chat-message: 6
#     messages over 3 UTC days between "the user" (isSender true) and Pat
#     Example (senderID "@example:pat"), including one type: NOTICE row
#     and one isDeleted: true row — 4 real content messages survive the
#     drop rules.
#   events/chat-fixture-subset.md — a second capture (different id,
#     thread-fixture-pat-002), same chatID, carrying only the first 2 of
#     chat-fixture.md's messages verbatim (same message ids) — file-thread
#     dedup test.
#   events/reaction-only.md — one REACTION-type row and one empty-text
#     TEXT row on the same day, same chatID/thread as neither content row
#     survives file-thread's activity filter.
#   events/unsolicited.md — one real message from a stranger with no
#     prior relationship to the user.
#   summaries/three-day.json — thread-summary 1.0.0 for chat-fixture.md:
#     one non-self person (Pat Example), one told-by-user fact, one
#     commitment, one open thread.
#   summaries/reaction-only.json — thread-summary for reaction-only.md,
#     no facts/commitments/open_threads (nothing survives to summarize).
#   summaries/skip.json — a skip summary (reason: bot) for chat-fixture.md.
#   summaries/unsolicited.json — thread-summary for unsolicited.md, the
#     one person's role_guess is "unsolicited".
#   summaries/inferred-fact.json — same as three-day.json but the one
#     fact's provenance is inferred-from-thread instead of told-by-user
#     (plan 32 person.md 1.3.0 Facts provenance) — used only by the guarded
#     assertion that checks whether validate-store.sh already accepts it.
#   claude-results/valid.json — a claude -p --output-format json result
#     whose "result" field is a ```json-fenced schema-valid summary object
#     (capture_id matches the fixture event's id).
#   claude-results/invalid-role.json — same shape, one people[] entry has
#     an invalid role_guess ("buddy") -> validate_summary must reject it.
#   claude-results/skip.json — a schema-valid skip summary (skip.reason:
#     "bot", people: []).
#   claude-results/not-json.json — a claude-result file whose "result"
#     field is plain prose, not JSON at all.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SUMMARIZE_THREAD="$REPO_ROOT/packages/ingestion/scripts/summarize-thread.sh"
FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/thread"
EVENT_FILE="$FIXTURES/events/chat-fixture.md"

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

if [ ! -f "$SUMMARIZE_THREAD" ]; then
  echo "SCRIPT NOT YET PRESENT: $SUMMARIZE_THREAD does not exist — tests unrun."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed (script not yet present)"
  exit 0
fi

if [ ! -x "$SUMMARIZE_THREAD" ]; then
  echo "FAIL: $SUMMARIZE_THREAD exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# =============================================================================
# --- summarize-thread.sh ---
# =============================================================================

# -----------------------------------------------------------------------
# Case 1 — dry run: prints a `claude -p` command with the default model
# (sonnet), the prompt excludes the NOTICE and deleted rows' text but
# includes all 4 real messages.
# -----------------------------------------------------------------------

c1_out="$WORK_DIR/c1-out.txt"
RA_THREAD_DRY_RUN=1 "$SUMMARIZE_THREAD" "$EVENT_FILE" > "$c1_out" 2>"$WORK_DIR/c1-err.txt"
c1_status=$?

if [ "$c1_status" -eq 0 ]; then
  pass "case 1: dry run exits 0"
else
  fail "case 1: dry run exited $c1_status: $(cat "$WORK_DIR/c1-err.txt")"
fi

if grep -q 'claude -p' "$c1_out" && grep -q -- '--model sonnet' "$c1_out"; then
  pass "case 1: dry run command line uses claude -p --model sonnet (default)"
else
  fail "case 1: dry run command line missing 'claude -p' / '--model sonnet'"
fi

if grep -q 'Pat Example changed the chat name' "$c1_out"; then
  fail "case 1: dry run prompt includes the NOTICE row's text (must be dropped)"
else
  pass "case 1: dry run prompt excludes the NOTICE row's text"
fi

if grep -q 'this text should never appear anywhere in the prompt' "$c1_out"; then
  fail "case 1: dry run prompt includes the deleted row's text (must be dropped)"
else
  pass "case 1: dry run prompt excludes the deleted row's text"
fi

c1_missing=""
for needle in \
  "hey are we still on for coffee thursday?" \
  "yes! also can you send me robs email, its rob@example.test right?" \
  "i will bring the report by friday" \
  "sounds good, see you then"
do
  grep -qF "$needle" "$c1_out" || c1_missing="$c1_missing|$needle"
done
if [ -z "$c1_missing" ]; then
  pass "case 1: dry run prompt includes all 4 real message texts"
else
  fail "case 1: dry run prompt missing message text(s): $c1_missing"
fi

# -----------------------------------------------------------------------
# Case 2 — --model flag wins over RA_THREAD_MODEL env.
# -----------------------------------------------------------------------

c2_out="$WORK_DIR/c2-out.txt"
RA_THREAD_DRY_RUN=1 RA_THREAD_MODEL=opus "$SUMMARIZE_THREAD" "$EVENT_FILE" --model sonnet > "$c2_out" 2>"$WORK_DIR/c2-err.txt"
c2_status=$?

if [ "$c2_status" -eq 0 ] && grep -q -- '--model sonnet' "$c2_out" && ! grep -q -- '--model opus' "$c2_out"; then
  pass "case 2: --model flag overrides RA_THREAD_MODEL env"
else
  fail "case 2: expected --model sonnet in dry-run output, not opus (status $c2_status)"
fi

# -----------------------------------------------------------------------
# Case 3 — parse-test, valid fenced claude-result JSON.
# -----------------------------------------------------------------------

c3_out="$WORK_DIR/c3-out.txt"
RA_THREAD_PARSE_TEST="$FIXTURES/claude-results/valid.json" "$SUMMARIZE_THREAD" > "$c3_out" 2>"$WORK_DIR/c3-err.txt"
c3_status=$?

if [ "$c3_status" -eq 0 ]; then
  pass "case 3: valid fenced claude-result parses and exits 0"
else
  fail "case 3: exited $c3_status: $(cat "$WORK_DIR/c3-err.txt")"
fi

c3_check=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print("not-json: %s" % e)
    sys.exit(0)
required = ["schema_version", "capture_id", "chat_id", "chat_type", "skip",
            "people", "relationship_kind_guess", "gist", "open_threads",
            "commitments", "facts"]
missing = [k for k in required if k not in data]
if missing:
    print("missing: %s" % missing)
elif len(data.keys()) != 11:
    print("key-count: %d" % len(data.keys()))
elif data.get("capture_id") != "thread-fixture-pat-001":
    print("capture_id-mismatch: %r" % data.get("capture_id"))
else:
    print("ok")
' "$c3_out")

if [ "$c3_check" = "ok" ]; then
  pass "case 3: stdout is valid JSON with all 11 top-level keys and matching capture_id"
else
  fail "case 3: $c3_check"
fi

# -----------------------------------------------------------------------
# Case 4 — parse-test, invalid role_guess -> exit 4 with reason on stderr.
# -----------------------------------------------------------------------

c4_out="$WORK_DIR/c4-out.txt"
c4_err="$WORK_DIR/c4-err.txt"
RA_THREAD_PARSE_TEST="$FIXTURES/claude-results/invalid-role.json" "$SUMMARIZE_THREAD" > "$c4_out" 2>"$c4_err"
c4_status=$?

if [ "$c4_status" -eq 4 ]; then
  pass "case 4: invalid role_guess exits 4"
else
  fail "case 4: expected exit 4, got $c4_status"
fi

if [ -s "$c4_err" ]; then
  pass "case 4: reason printed on stderr"
else
  fail "case 4: expected a reason on stderr, got none"
fi

# -----------------------------------------------------------------------
# Case 5 — parse-test, skip result -> exit 0, people may be empty.
# -----------------------------------------------------------------------

c5_out="$WORK_DIR/c5-out.txt"
RA_THREAD_PARSE_TEST="$FIXTURES/claude-results/skip.json" "$SUMMARIZE_THREAD" > "$c5_out" 2>"$WORK_DIR/c5-err.txt"
c5_status=$?

if [ "$c5_status" -eq 0 ]; then
  pass "case 5: skip result exits 0"
else
  fail "case 5: exited $c5_status: $(cat "$WORK_DIR/c5-err.txt")"
fi

c5_check=$(python3 -c '
import json, sys
data = json.load(open(sys.argv[1]))
skip = data.get("skip")
if not isinstance(skip, dict) or skip.get("reason") != "bot":
    print("bad-skip: %r" % (skip,))
elif not isinstance(data.get("people"), list):
    print("people-not-list")
else:
    print("ok")
' "$c5_out" 2>&1)
if [ "$c5_check" = "ok" ]; then
  pass "case 5: skip result has skip.reason bot and people is a (empty) list"
else
  fail "case 5: $c5_check"
fi

# -----------------------------------------------------------------------
# Case 6 — parse-test, result field is not JSON at all -> exit 4.
# -----------------------------------------------------------------------

RA_THREAD_PARSE_TEST="$FIXTURES/claude-results/not-json.json" "$SUMMARIZE_THREAD" > "$WORK_DIR/c6-out.txt" 2>"$WORK_DIR/c6-err.txt"
c6_status=$?

if [ "$c6_status" -eq 4 ]; then
  pass "case 6: non-JSON result field exits 4"
else
  fail "case 6: expected exit 4, got $c6_status"
fi

# -----------------------------------------------------------------------
# Case 7 — usage errors.
# -----------------------------------------------------------------------

"$SUMMARIZE_THREAD" > "$WORK_DIR/c7a-out.txt" 2>"$WORK_DIR/c7a-err.txt"
c7a_status=$?
if [ "$c7a_status" -eq 2 ]; then
  pass "case 7: no args exits 2"
else
  fail "case 7: expected exit 2 for no args, got $c7a_status"
fi

"$SUMMARIZE_THREAD" "$WORK_DIR/does-not-exist.md" > "$WORK_DIR/c7b-out.txt" 2>"$WORK_DIR/c7b-err.txt"
c7b_status=$?
if [ "$c7b_status" -eq 2 ]; then
  pass "case 7: missing event file exits 2"
else
  fail "case 7: expected exit 2 for missing file, got $c7b_status"
fi

# -----------------------------------------------------------------------
# Case 8 — --out <path> writes the JSON there and prints nothing to
# stdout. No live model call: a stub `claude` executable is placed ahead
# of the real one on PATH, returning a canned schema-valid result.
# -----------------------------------------------------------------------

STUB_BIN="$WORK_DIR/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
python3 -c '
import json
obj = {
    "schema_version": "1.0.0",
    "capture_id": "thread-fixture-pat-001",
    "chat_id": "chat-pat-example",
    "chat_type": "single",
    "skip": None,
    "people": [{"display_name": "Pat Example", "sender_ids": ["@example:pat"],
                "is_self": False, "role_guess": "friend"}],
    "relationship_kind_guess": "friend",
    "gist": "Stubbed gist for --out test.",
    "open_threads": [],
    "commitments": [],
    "facts": [],
}
print(json.dumps({"result": json.dumps(obj)}))
'
STUB
chmod +x "$STUB_BIN/claude"

c8_out_path="$WORK_DIR/c8-summary.json"
c8_stdout="$WORK_DIR/c8-out.txt"
PATH="$STUB_BIN:$PATH" "$SUMMARIZE_THREAD" "$EVENT_FILE" --out "$c8_out_path" > "$c8_stdout" 2>"$WORK_DIR/c8-err.txt"
c8_status=$?

if [ "$c8_status" -eq 0 ]; then
  pass "case 8: --out run exits 0"
else
  fail "case 8: --out run exited $c8_status: $(cat "$WORK_DIR/c8-err.txt")"
fi

if [ ! -s "$c8_stdout" ]; then
  pass "case 8: nothing printed to stdout"
else
  fail "case 8: expected empty stdout, got: $(cat "$c8_stdout")"
fi

if [ -s "$c8_out_path" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$c8_out_path" >/dev/null 2>&1; then
  pass "case 8: --out path contains valid JSON"
else
  fail "case 8: --out path missing or not valid JSON"
fi

# =============================================================================
# --- file-thread.sh ---
# =============================================================================

FILE_THREAD="$REPO_ROOT/packages/ingestion/scripts/file-thread.sh"
BUILD_INDEX="$REPO_ROOT/packages/core/scripts/build-index.sh"
VALIDATE_STORE="$REPO_ROOT/packages/core/scripts/validate-store.sh"

if [ ! -f "$FILE_THREAD" ]; then
  echo "SCRIPT NOT YET PRESENT: $FILE_THREAD does not exist — file-thread.sh cases unrun."
elif [ ! -x "$FILE_THREAD" ]; then
  fail "file-thread.sh: $FILE_THREAD exists but is not executable"
else

# ft_new_store <dir> — creates people/interactions/inbox/wakeups under <dir>
# (the four dirs file-thread.sh and validate-store.sh both need).
ft_new_store() {
  mkdir -p "$1/people" "$1/interactions" "$1/inbox" "$1/wakeups"
}

# -----------------------------------------------------------------------
# Case 1 — 3-day thread: 3 interactions, 1 person, correct dates,
# last-day-only Commitments/Open lines, ledger has the id, validate-store
# clean after build-index.
# -----------------------------------------------------------------------

ft1_store="$WORK_DIR/ft1-store"
ft1_data="$WORK_DIR/ft1-data"
ft_new_store "$ft1_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft1_store/inbox/"

ft1_out="$WORK_DIR/ft1-out.txt"
"$FILE_THREAD" "$ft1_store" "$ft1_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft1_data" > "$ft1_out" 2>"$WORK_DIR/ft1-err.txt"
ft1_status=$?

if [ "$ft1_status" -eq 0 ] && grep -q '^file-thread: thread-fixture-pat-001 people_new=1 people_touched=1 interactions=3 days=3 dedup_ids=1$' "$ft1_out"; then
  pass "ft case 1: prints the expected summary line and exits 0"
else
  fail "ft case 1: exited $ft1_status, got: $(cat "$ft1_out") $(cat "$WORK_DIR/ft1-err.txt")"
fi

ft1_people_count="$(ls "$ft1_store/people" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ft1_people_count" = "1" ]; then
  pass "ft case 1: exactly one person file written"
else
  fail "ft case 1: expected 1 person file, got $ft1_people_count"
fi

if [ -f "$ft1_store/interactions/2026-08-10-pat-example.md" ] \
  && [ -f "$ft1_store/interactions/2026-08-11-pat-example.md" ] \
  && [ -f "$ft1_store/interactions/2026-08-12-pat-example.md" ]; then
  pass "ft case 1: one interaction per active day, correct dates"
else
  fail "ft case 1: expected interactions dated 2026-08-10/11/12, got: $(ls "$ft1_store/interactions" 2>/dev/null)"
fi

if grep -q '^_none_$' "$ft1_store/interactions/2026-08-10-pat-example.md" \
  && grep -q '^_none_$' "$ft1_store/interactions/2026-08-11-pat-example.md"; then
  pass "ft case 1: non-last days have _none_ commitments"
else
  fail "ft case 1: expected _none_ commitments on the non-last days"
fi

if grep -q 'Open: confirm coffee thursday' "$ft1_store/interactions/2026-08-12-pat-example.md" \
  && grep -q '\[\[pat-example\]\]: bring the report \[by friday\]' "$ft1_store/interactions/2026-08-12-pat-example.md"; then
  pass "ft case 1: last day carries the open thread and commitment"
else
  fail "ft case 1: last-day interaction missing the open thread / commitment line"
fi

if grep -qx "thread-fixture-pat-001" "$ft1_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "ft case 1: ledger has the capture id"
else
  fail "ft case 1: ledger missing thread-fixture-pat-001"
fi

"$BUILD_INDEX" "$ft1_store" >/dev/null 2>&1
ft1_validate_out="$("$VALIDATE_STORE" "$ft1_store" 2>&1)"
ft1_validate_status=$?
if [ "$ft1_validate_status" -eq 0 ]; then
  pass "ft case 1: validate-store.sh clean after build-index"
else
  fail "ft case 1: validate-store.sh not clean: $ft1_validate_out"
fi

if grep -Eq '^(tier|tier_source|kind):' "$ft1_store/people/pat-example.md"; then
  fail "ft case 9: new person file carries a tier:/tier_source:/kind line (must never)"
else
  pass "ft case 9: new person file never carries tier:/tier_source:/kind lines"
fi

# -----------------------------------------------------------------------
# Case 2 — a second capture with the same chatID, a 2-message subset:
# filed once, both ids in the ledger, dedup_ids=2.
# -----------------------------------------------------------------------

ft2_store="$WORK_DIR/ft2-store"
ft2_data="$WORK_DIR/ft2-data"
ft_new_store "$ft2_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft2_store/inbox/"
cp "$FIXTURES/events/chat-fixture-subset.md" "$ft2_store/inbox/"

ft2_out="$WORK_DIR/ft2-out.txt"
"$FILE_THREAD" "$ft2_store" "$ft2_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft2_data" > "$ft2_out" 2>"$WORK_DIR/ft2-err.txt"

if grep -q 'dedup_ids=2$' "$ft2_out"; then
  pass "ft case 2: dedup_ids=2 with a same-chatID subset capture present"
else
  fail "ft case 2: expected dedup_ids=2, got: $(cat "$ft2_out")"
fi

if grep -qx "thread-fixture-pat-001" "$ft2_data/ingestion/debrief-filed.log" 2>/dev/null \
  && grep -qx "thread-fixture-pat-002" "$ft2_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "ft case 2: both capture ids land in the ledger"
else
  fail "ft case 2: ledger missing one or both capture ids: $(cat "$ft2_data/ingestion/debrief-filed.log" 2>/dev/null)"
fi

# -----------------------------------------------------------------------
# Case 3 — a REACTION-only day plus an empty-text row: no interaction, no
# active day counted.
# -----------------------------------------------------------------------

ft3_store="$WORK_DIR/ft3-store"
ft3_data="$WORK_DIR/ft3-data"
ft_new_store "$ft3_store"
cp "$FIXTURES/events/reaction-only.md" "$ft3_store/inbox/"

ft3_out="$WORK_DIR/ft3-out.txt"
"$FILE_THREAD" "$ft3_store" "$ft3_store/inbox/reaction-only.md" "$FIXTURES/summaries/reaction-only.json" --data-dir "$ft3_data" > "$ft3_out" 2>"$WORK_DIR/ft3-err.txt"

if grep -q '^file-thread: thread-fixture-reaction-only people_new=0 people_touched=0 interactions=0 days=0 dedup_ids=1$' "$ft3_out"; then
  pass "ft case 3: a REACTION-only day + empty-text row produce no interaction"
else
  fail "ft case 3: expected all-zero interactions/days, got: $(cat "$ft3_out")"
fi

ft3_int_count="$(ls "$ft3_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ft3_int_count" = "0" ]; then
  pass "ft case 3: no interaction file written"
else
  fail "ft case 3: expected 0 interaction files, got $ft3_int_count"
fi

# -----------------------------------------------------------------------
# Case 4 — rerun over the same store/data-dir: all zeros, file counts
# unchanged.
# -----------------------------------------------------------------------

ft4_store="$WORK_DIR/ft4-store"
ft4_data="$WORK_DIR/ft4-data"
ft_new_store "$ft4_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft4_store/inbox/"
"$FILE_THREAD" "$ft4_store" "$ft4_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft4_data" >/dev/null 2>&1
ft4_people_before="$(ls "$ft4_store/people" 2>/dev/null | wc -l | tr -d ' ')"
ft4_int_before="$(ls "$ft4_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"

ft4_rerun_out="$WORK_DIR/ft4-rerun-out.txt"
"$FILE_THREAD" "$ft4_store" "$ft4_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft4_data" > "$ft4_rerun_out" 2>"$WORK_DIR/ft4-rerun-err.txt"

if grep -q '^file-thread: thread-fixture-pat-001 people_new=0 people_touched=0 interactions=0 days=0 dedup_ids=0$' "$ft4_rerun_out"; then
  pass "ft case 4: rerun prints all zeros"
else
  fail "ft case 4: rerun did not print all zeros, got: $(cat "$ft4_rerun_out")"
fi

ft4_people_after="$(ls "$ft4_store/people" 2>/dev/null | wc -l | tr -d ' ')"
ft4_int_after="$(ls "$ft4_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ft4_people_before" = "$ft4_people_after" ] && [ "$ft4_int_before" = "$ft4_int_after" ]; then
  pass "ft case 4: file counts unchanged after rerun"
else
  fail "ft case 4: file counts changed: people $ft4_people_before->$ft4_people_after, interactions $ft4_int_before->$ft4_int_after"
fi

# -----------------------------------------------------------------------
# Case 5 — skip summary: ledgered, nothing written.
# -----------------------------------------------------------------------

ft5_store="$WORK_DIR/ft5-store"
ft5_data="$WORK_DIR/ft5-data"
ft_new_store "$ft5_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft5_store/inbox/"

ft5_out="$WORK_DIR/ft5-out.txt"
"$FILE_THREAD" "$ft5_store" "$ft5_store/inbox/chat-fixture.md" "$FIXTURES/summaries/skip.json" --data-dir "$ft5_data" > "$ft5_out" 2>"$WORK_DIR/ft5-err.txt"

if grep -q '^file-thread: thread-fixture-pat-001 skipped=bot$' "$ft5_out"; then
  pass "ft case 5: skip summary prints skipped=bot"
else
  fail "ft case 5: expected skipped=bot, got: $(cat "$ft5_out")"
fi

if grep -qx "thread-fixture-pat-001" "$ft5_data/ingestion/debrief-filed.log" 2>/dev/null; then
  pass "ft case 5: skip still ledgers the capture id"
else
  fail "ft case 5: capture id missing from ledger after skip"
fi

ft5_people_count="$(ls "$ft5_store/people" 2>/dev/null | wc -l | tr -d ' ')"
ft5_int_count="$(ls "$ft5_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ft5_people_count" = "0" ] && [ "$ft5_int_count" = "0" ]; then
  pass "ft case 5: skip writes no person/interaction files"
else
  fail "ft case 5: skip wrote files: people=$ft5_people_count interactions=$ft5_int_count"
fi

# -----------------------------------------------------------------------
# Case 6 — existing person with the same normalized name is reused (no
# -2 slug); last-touch never moves backward.
# -----------------------------------------------------------------------

ft6_store="$WORK_DIR/ft6-store"
ft6_data="$WORK_DIR/ft6-data"
ft_new_store "$ft6_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft6_store/inbox/"
cat > "$ft6_store/people/pat-example.md" <<'PERSONEOF'
---
schema_version: 1.1.0
name: Pat Example
org:
role:
location:
tags: []
birthday:
how-met:
last-touch: 2026-09-01
---

## Facts

_none_

## Open threads

_none_

## Personal details

_none_
PERSONEOF

ft6_out="$WORK_DIR/ft6-out.txt"
"$FILE_THREAD" "$ft6_store" "$ft6_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft6_data" > "$ft6_out" 2>"$WORK_DIR/ft6-err.txt"

if [ -f "$ft6_store/people/pat-example.md" ] && [ ! -f "$ft6_store/people/pat-example-2.md" ]; then
  pass "ft case 6: existing person reused, no -2 slug minted"
else
  fail "ft case 6: expected pat-example.md reused with no -2 slug, got: $(ls "$ft6_store/people" 2>/dev/null)"
fi

if grep -qx "last-touch: 2026-09-01" "$ft6_store/people/pat-example.md"; then
  pass "ft case 6: last-touch never moves backward (stays 2026-09-01)"
else
  fail "ft case 6: last-touch moved backward: $(grep last-touch "$ft6_store/people/pat-example.md")"
fi

if grep -q 'people_new=0' "$ft6_out"; then
  pass "ft case 6: people_new=0 (no new person minted)"
else
  fail "ft case 6: expected people_new=0, got: $(cat "$ft6_out")"
fi

# -----------------------------------------------------------------------
# Case 7 — --dry-run writes nothing (no files, no ledger) but prints the
# summary line.
# -----------------------------------------------------------------------

ft7_store="$WORK_DIR/ft7-store"
ft7_data="$WORK_DIR/ft7-data"
ft_new_store "$ft7_store"
cp "$FIXTURES/events/chat-fixture.md" "$ft7_store/inbox/"

ft7_out="$WORK_DIR/ft7-out.txt"
"$FILE_THREAD" "$ft7_store" "$ft7_store/inbox/chat-fixture.md" "$FIXTURES/summaries/three-day.json" --data-dir "$ft7_data" --dry-run > "$ft7_out" 2>"$WORK_DIR/ft7-err.txt"

if grep -q '^file-thread: thread-fixture-pat-001 people_new=1 people_touched=1 interactions=3 days=3 dedup_ids=1$' "$ft7_out"; then
  pass "ft case 7: --dry-run still prints the summary line"
else
  fail "ft case 7: --dry-run summary line missing/wrong: $(cat "$ft7_out")"
fi

ft7_people_count="$(ls "$ft7_store/people" 2>/dev/null | wc -l | tr -d ' ')"
ft7_int_count="$(ls "$ft7_store/interactions" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ft7_people_count" = "0" ] && [ "$ft7_int_count" = "0" ] && [ ! -d "$ft7_data/ingestion" ]; then
  pass "ft case 7: --dry-run writes no person/interaction files and no ledger"
else
  fail "ft case 7: --dry-run wrote something: people=$ft7_people_count interactions=$ft7_int_count ledger-dir-exists=$([ -d "$ft7_data/ingestion" ] && echo yes || echo no)"
fi

# -----------------------------------------------------------------------
# Case 8 — role_guess unsolicited -> new person carries
# tags: [linkedin-outreach].
# -----------------------------------------------------------------------

ft8_store="$WORK_DIR/ft8-store"
ft8_data="$WORK_DIR/ft8-data"
ft_new_store "$ft8_store"
cp "$FIXTURES/events/unsolicited.md" "$ft8_store/inbox/"

"$FILE_THREAD" "$ft8_store" "$ft8_store/inbox/unsolicited.md" "$FIXTURES/summaries/unsolicited.json" --data-dir "$ft8_data" > "$WORK_DIR/ft8-out.txt" 2>"$WORK_DIR/ft8-err.txt"

if [ -f "$ft8_store/people/alex-stranger.md" ] && grep -qx "tags: \[linkedin-outreach\]" "$ft8_store/people/alex-stranger.md"; then
  pass "ft case 8: unsolicited role_guess -> tags: [linkedin-outreach]"
else
  fail "ft case 8: expected tags: [linkedin-outreach] on the new person file"
fi

# -----------------------------------------------------------------------
# Guarded case — inferred-from-thread provenance (person.md 1.3.0, plan
# 32). Only asserted clean against validate-store.sh once that script's
# Facts provenance enum includes inferred-from-thread; otherwise SKIP
# (the fixture itself is still exercised through file-thread.sh either
# way, so the writer path is always covered).
# -----------------------------------------------------------------------

ftg_store="$WORK_DIR/ftg-store"
ftg_data="$WORK_DIR/ftg-data"
ft_new_store "$ftg_store"
cp "$FIXTURES/events/chat-fixture.md" "$ftg_store/inbox/"
"$FILE_THREAD" "$ftg_store" "$ftg_store/inbox/chat-fixture.md" "$FIXTURES/summaries/inferred-fact.json" --data-dir "$ftg_data" > "$WORK_DIR/ftg-out.txt" 2>"$WORK_DIR/ftg-err.txt"

if grep -q '\*\*\[inferred-from-thread\]\*\*' "$ftg_store/people/pat-example.md"; then
  pass "ft guarded case: inferred-from-thread fact bullet written to the person file"
else
  fail "ft guarded case: inferred-from-thread fact bullet missing from the person file"
fi

if grep -q "inferred-from-thread" "$VALIDATE_STORE"; then
  "$BUILD_INDEX" "$ftg_store" >/dev/null 2>&1
  ftg_validate_out="$("$VALIDATE_STORE" "$ftg_store" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "ft guarded case: validate-store.sh accepts inferred-from-thread cleanly (core 1.3.0 landed)"
  else
    fail "ft guarded case: validate-store.sh claims to support inferred-from-thread but rejected it: $ftg_validate_out"
  fi
else
  echo "SKIP: ft guarded case — validate-store.sh does not yet enumerate inferred-from-thread (core 1.3.0 pending)"
fi

fi
# end file-thread.sh section

# =============================================================================

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
