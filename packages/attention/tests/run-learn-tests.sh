#!/usr/bin/env bash
# packages/attention/tests/run-learn-tests.sh
#
# Test suite for learn-sweep.sh (plan 36 D): proves the cursor walk, the
# learned-eval generation via feedback-to-evals.sh, conflict hold/resolve
# semantics, --dry-run, and the never-writes invariant.
#
# Mission test: guards that a correction is paid once (an eval case for it
# stands, never re-explained) and a disagreement is surfaced, never
# silently resolved (a same-slug/same-type conflict is held, not
# "latest wins", until a later conflict-free correction resolves it).
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LEARN_SWEEP="$REPO_ROOT/packages/attention/scripts/learn-sweep.sh"
FIXTURE_STORE="$REPO_ROOT/packages/attention/tests/fixtures/learn-sweep/store"

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

if [ ! -f "$LEARN_SWEEP" ]; then
  echo "SKIP: $LEARN_SWEEP not found — cannot run learn-sweep tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, learn-sweep.sh missing"
  exit 1
fi

if [ ! -x "$LEARN_SWEEP" ]; then
  fail "$LEARN_SWEEP exists but is not executable"
fi

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found — cannot run learn-sweep tests."; echo ""; echo "SUMMARY: 0 passed, 0 failed, jq missing"; exit 1; }

if [ ! -d "$FIXTURE_STORE" ]; then
  fail "fixture missing: $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
  exit 1
fi

WORKDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'learn-sweep-test')"
trap 'rm -rf "$WORKDIR"' EXIT

# fresh_store <name> — a fresh copy of the fixture store under
# $WORKDIR/<name>-store; prints the path.
fresh_store() {
  _dst="$WORKDIR/$1-store"
  cp -R "$FIXTURE_STORE" "$_dst"
  printf '%s' "$_dst"
}

# sha_all <dir> <file...> — a stable combined sha of the given files
# (relative to nothing in particular, just for before/after comparison).
sha_all() {
  _out=""
  for _f in "$@"; do
    if [ -f "$_f" ]; then
      _out="$_out$(shasum -a 256 "$_f" 2>/dev/null | awk '{print $1}')"
    else
      _out="${_out}MISSING:$_f"
    fi
  done
  printf '%s' "$_out"
}

# =============================================================================
# Scenario 1 + 2: first sweep (learn, conflict-hold, evals) and the
# never-writes invariant, run against the same store.
# =============================================================================

STORE1="$(fresh_store s1)"
DATA1="$WORKDIR/s1-data"

# --- never-writes invariant: hash guarded files before the sweep ---
S1_PEOPLE_FILES="$STORE1/people/jane-doe.md $STORE1/people/sam-okafor.md $STORE1/people/bob-cpa.md"
S1_GUARDED="$STORE1/user-model.md $S1_PEOPLE_FILES $STORE1/signals/feedback.jsonl"
S1_HASH_BEFORE="$(sha_all $S1_GUARDED)"

s1_out="$("$LEARN_SWEEP" "$STORE1" --data-dir "$DATA1" 2>"$WORKDIR/s1-stderr")"
s1_status=$?
s1_err="$(cat "$WORKDIR/s1-stderr" 2>/dev/null)"

if [ "$s1_status" -eq 0 ]; then
  pass "first sweep: exits 0"
else
  fail "first sweep: expected exit 0, got $s1_status ($s1_out / $s1_err)"
fi

s1_line1="$(printf '%s\n' "$s1_out" | sed -n '1p')"
s1_line2="$(printf '%s\n' "$s1_out" | sed -n '2p')"
s1_line3="$(printf '%s\n' "$s1_out" | sed -n '3p')"
s1_line_count="$(printf '%s\n' "$s1_out" | grep -c '.')"

if [ "$s1_line_count" -eq 3 ]; then
  pass "first sweep: exactly 3 stdout lines"
else
  fail "first sweep: expected exactly 3 stdout lines, got $s1_line_count: [$s1_out]"
fi

for _l in "$s1_line1" "$s1_line2" "$s1_line3"; do
  case "$_l" in
    "learn-sweep: "*) : ;;
    *) fail "first sweep: line does not start with 'learn-sweep: ' -> [$_l]" ;;
  esac
done

if [ "$s1_line1" = "learn-sweep: learned 2 new correction(s) → 2 eval case(s) standing" ]; then
  pass "first sweep: line1 exact match (learned 2 new, 2 cases standing)"
else
  fail "first sweep: line1 mismatch, got [$s1_line1]"
fi

if printf '%s' "$s1_line2" | grep -q "1 conflict(s) held for you" && printf '%s' "$s1_line2" | grep -qF "learn-conflicts.tsv"; then
  pass "first sweep: line2 reports 1 conflict held and names the tsv path"
else
  fail "first sweep: line2 mismatch, got [$s1_line2]"
fi

if [ "$s1_line3" = "learn-sweep: cursor 0 → 5 (5 new lines)" ]; then
  pass "first sweep: line3 exact match (cursor 0 -> 5, 5 new lines)"
else
  fail "first sweep: line3 mismatch, got [$s1_line3]"
fi

CURSOR1="$DATA1/attention/learn-sweep.cursor"
if [ -f "$CURSOR1" ] && [ "$(cat "$CURSOR1")" = "5" ]; then
  pass "first sweep: cursor file contains 5"
else
  fail "first sweep: cursor file mismatch, got [$(cat "$CURSOR1" 2>/dev/null)]"
fi

CONFLICTS1="$DATA1/attention/learn-conflicts.tsv"
if [ -f "$CONFLICTS1" ]; then
  conflict_row_count="$(grep -c '.' "$CONFLICTS1")"
  if [ "$conflict_row_count" -eq 1 ]; then
    pass "first sweep: conflicts tsv has exactly one row"
  else
    fail "first sweep: expected exactly 1 conflict row, got $conflict_row_count"
  fi
  conflict_row="$(sed -n '1p' "$CONFLICTS1")"
  case_field="$(printf '%s' "$conflict_row" | cut -f1)"
  status_field="$(printf '%s' "$conflict_row" | cut -f2)"
  first_to_field="$(printf '%s' "$conflict_row" | cut -f4)"
  second_to_field="$(printf '%s' "$conflict_row" | cut -f6)"
  if [ "$case_field" = "sam-okafor-tier-correction" ] && [ "$status_field" = "held" ] \
    && [ "$first_to_field" = "close" ] && [ "$second_to_field" = "dormant" ]; then
    pass "first sweep: conflict row shape (case/status/first_to/second_to) matches"
  else
    fail "first sweep: conflict row mismatch: [$conflict_row]"
  fi
else
  fail "first sweep: conflicts tsv not found at $CONFLICTS1"
fi

CASES1="$DATA1/evals/feedback/cases"
if [ -d "$CASES1/jane-doe-tier-correction" ] && [ -d "$CASES1/bob-cpa-kind-correction" ] \
  && [ ! -d "$CASES1/sam-okafor-tier-correction" ]; then
  pass "first sweep: evals cases has jane-doe + bob-cpa, not the held sam-okafor case"
else
  fail "first sweep: evals cases mismatch: $(ls "$CASES1" 2>&1)"
fi

SUITE1="$DATA1/evals/feedback/suite.txt"
suite1_lines="$(grep -vc '^#' "$SUITE1" 2>/dev/null)"
if [ "$suite1_lines" = "2" ]; then
  pass "first sweep: suite.txt has exactly 2 case lines"
else
  fail "first sweep: expected 2 suite.txt case lines, got $suite1_lines"
fi

# --- Scenario 2: never-writes invariant ---
S1_HASH_AFTER="$(sha_all $S1_GUARDED)"
if [ "$S1_HASH_BEFORE" = "$S1_HASH_AFTER" ]; then
  pass "never-writes: user-model.md, people/*.md, signals/feedback.jsonl unchanged after a sweep"
else
  fail "never-writes: at least one guarded store file changed after a sweep"
fi

if [ ! -f "$STORE1/ranking-weights.json" ]; then
  pass "never-writes: no ranking-weights.json created in the store"
else
  fail "never-writes: ranking-weights.json was created in the store"
fi

# =============================================================================
# Scenario 3: idempotent re-run against the same store + data-dir
# =============================================================================

CONFLICTS1_SNAPSHOT="$WORKDIR/s1-conflicts-snapshot.tsv"
cp "$CONFLICTS1" "$CONFLICTS1_SNAPSHOT" 2>/dev/null

s3_out="$("$LEARN_SWEEP" "$STORE1" --data-dir "$DATA1" 2>&1)"
s3_status=$?

if [ "$s3_status" -eq 0 ]; then
  pass "idempotent re-run: exits 0"
else
  fail "idempotent re-run: expected exit 0, got $s3_status ($s3_out)"
fi

s3_line1="$(printf '%s\n' "$s3_out" | sed -n '1p')"
s3_line3="$(printf '%s\n' "$s3_out" | sed -n '3p')"

if printf '%s' "$s3_line1" | grep -q "learned 0 new"; then
  pass "idempotent re-run: line1 reports learned 0 new"
else
  fail "idempotent re-run: line1 mismatch, got [$s3_line1]"
fi

if [ "$s3_line3" = "learn-sweep: cursor 5 → 5 (0 new lines)" ]; then
  pass "idempotent re-run: line3 exact match (cursor 5 -> 5, 0 new lines)"
else
  fail "idempotent re-run: line3 mismatch, got [$s3_line3]"
fi

if diff "$CONFLICTS1_SNAPSHOT" "$CONFLICTS1" >/dev/null 2>&1; then
  pass "idempotent re-run: conflicts tsv byte-identical"
else
  fail "idempotent re-run: conflicts tsv changed"
fi

s3_case_count="$(find "$CASES1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s3_case_count" = "2" ]; then
  pass "idempotent re-run: still exactly 2 cases"
else
  fail "idempotent re-run: expected 2 cases, got $s3_case_count"
fi

# =============================================================================
# Scenario 4: resolution — a later conflict-free correction flips a held
# case to resolved and the correction is finally learned.
# =============================================================================

jq -n -c '{ts:"2026-08-24T09:00:00Z", type:"tier-correction", target:"person:sam-okafor", from:"dormant", to:"close", reason:null, text:"reconnected", channel:null, source:"session"}' >> "$STORE1/signals/feedback.jsonl"

s4_out="$("$LEARN_SWEEP" "$STORE1" --data-dir "$DATA1" 2>&1)"
s4_status=$?

if [ "$s4_status" -eq 0 ]; then
  pass "resolution sweep: exits 0"
else
  fail "resolution sweep: expected exit 0, got $s4_status ($s4_out)"
fi

s4_line2="$(printf '%s\n' "$s4_out" | sed -n '2p')"
if printf '%s' "$s4_line2" | grep -q "0 conflict(s) held"; then
  pass "resolution sweep: line2 reports 0 conflicts held"
else
  fail "resolution sweep: line2 mismatch, got [$s4_line2]"
fi

resolved_row="$(grep '^sam-okafor-tier-correction' "$CONFLICTS1" | tail -1)"
resolved_status="$(printf '%s' "$resolved_row" | cut -f2)"
if [ "$resolved_status" = "resolved" ]; then
  pass "resolution sweep: sam-okafor-tier-correction row flips to resolved"
else
  fail "resolution sweep: expected resolved status, got [$resolved_row]"
fi

if [ -d "$CASES1/sam-okafor-tier-correction" ]; then
  pass "resolution sweep: sam-okafor-tier-correction case now exists"
else
  fail "resolution sweep: sam-okafor-tier-correction case still missing"
fi

s4_case_count="$(find "$CASES1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$s4_case_count" = "3" ]; then
  pass "resolution sweep: exactly 3 cases now"
else
  fail "resolution sweep: expected 3 cases, got $s4_case_count"
fi

if [ "$(cat "$CURSOR1")" = "6" ]; then
  pass "resolution sweep: cursor advances to 6"
else
  fail "resolution sweep: expected cursor 6, got [$(cat "$CURSOR1" 2>/dev/null)]"
fi

# =============================================================================
# Scenario 5: a chain (B.from == A.to) is not a conflict.
# =============================================================================

STORE5="$(fresh_store s5)"
DATA5="$WORKDIR/s5-data"
mkdir -p "$STORE5/signals"
: > "$STORE5/signals/feedback.jsonl"
jq -n -c '{ts:"2026-08-20T14:00:00Z", type:"tier-correction", target:"person:jane-doe", from:"active", to:"close", reason:null, text:"getting closer", channel:null, source:"session"}' >> "$STORE5/signals/feedback.jsonl"
jq -n -c '{ts:"2026-08-21T14:00:00Z", type:"tier-correction", target:"person:jane-doe", from:"close", to:"dormant", reason:null, text:"actually drifted", channel:null, source:"session"}' >> "$STORE5/signals/feedback.jsonl"

s5_out="$("$LEARN_SWEEP" "$STORE5" --data-dir "$DATA5" 2>&1)"
s5_status=$?

if [ "$s5_status" -eq 0 ]; then
  pass "chain: exits 0"
else
  fail "chain: expected exit 0, got $s5_status ($s5_out)"
fi

s5_line2="$(printf '%s\n' "$s5_out" | sed -n '2p')"
if printf '%s' "$s5_line2" | grep -q "0 conflict(s)"; then
  pass "chain: reports 0 conflicts (chain, not a conflict)"
else
  fail "chain: expected 0 conflicts, got [$s5_line2]"
fi

CASE5_DIR="$DATA5/evals/feedback/cases/jane-doe-tier-correction"
case5_count="$(find "$DATA5/evals/feedback/cases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if [ "$case5_count" = "1" ]; then
  pass "chain: exactly 1 case"
else
  fail "chain: expected 1 case, got $case5_count"
fi

if grep -qF "tier: dormant" "$CASE5_DIR/graders/01-stated-holds.sh" 2>/dev/null; then
  pass "chain: the surviving case's grader asserts tier: dormant (the chain's final value)"
else
  fail "chain: grader does not assert tier: dormant"
fi

# =============================================================================
# Scenario 6: --dry-run writes nothing.
# =============================================================================

STORE6="$(fresh_store s6)"
DATA6="$WORKDIR/s6-data"

s6_out="$("$LEARN_SWEEP" "$STORE6" --data-dir "$DATA6" --dry-run 2>&1)"
s6_status=$?

if [ "$s6_status" -eq 0 ]; then
  pass "dry-run: exits 0"
else
  fail "dry-run: expected exit 0, got $s6_status ($s6_out)"
fi

s6_line_count="$(printf '%s\n' "$s6_out" | grep -c '.')"
if [ "$s6_line_count" -eq 3 ]; then
  pass "dry-run: exactly 3 stdout lines"
else
  fail "dry-run: expected 3 stdout lines, got $s6_line_count: [$s6_out]"
fi

s6_line3="$(printf '%s\n' "$s6_out" | sed -n '3p')"
case "$s6_line3" in
  *"(dry-run)") pass "dry-run: line3 ends with (dry-run)" ;;
  *) fail "dry-run: line3 does not end with (dry-run), got [$s6_line3]" ;;
esac

if [ ! -d "$DATA6/attention" ]; then
  pass "dry-run: no <data-dir>/attention dir created"
else
  fail "dry-run: <data-dir>/attention was created"
fi

if [ ! -d "$DATA6/evals" ]; then
  pass "dry-run: no <data-dir>/evals dir created"
else
  fail "dry-run: <data-dir>/evals was created"
fi

# =============================================================================
# Scenario 7: ledger shorter than the recorded cursor -> WARN + reprocess
# from 0.
# =============================================================================

STORE7="$(fresh_store s7)"
DATA7="$WORKDIR/s7-data"
mkdir -p "$DATA7/attention"
printf '99' > "$DATA7/attention/learn-sweep.cursor"

s7_out="$("$LEARN_SWEEP" "$STORE7" --data-dir "$DATA7" 2>"$WORKDIR/s7-stderr")"
s7_status=$?
s7_err="$(cat "$WORKDIR/s7-stderr")"

if [ "$s7_status" -eq 0 ]; then
  pass "ledger-shorter-than-cursor: exits 0"
else
  fail "ledger-shorter-than-cursor: expected exit 0, got $s7_status ($s7_out / $s7_err)"
fi

if printf '%s' "$s7_err" | grep -q "WARN ledger shorter than cursor"; then
  pass "ledger-shorter-than-cursor: stderr carries the WARN"
else
  fail "ledger-shorter-than-cursor: expected WARN on stderr, got [$s7_err]"
fi

s7_line3="$(printf '%s\n' "$s7_out" | sed -n '3p')"
case "$s7_line3" in
  "learn-sweep: cursor 0 → 5"*) pass "ledger-shorter-than-cursor: line3 reprocesses from cursor 0" ;;
  *) fail "ledger-shorter-than-cursor: line3 mismatch, got [$s7_line3]" ;;
esac

# =============================================================================
# Scenario 8: missing ledger.
# =============================================================================

STORE8="$(fresh_store s8)"
DATA8="$WORKDIR/s8-data"
rm -f "$STORE8/signals/feedback.jsonl"

s8_out="$("$LEARN_SWEEP" "$STORE8" --data-dir "$DATA8" 2>&1)"
s8_status=$?

if [ "$s8_status" -eq 0 ]; then
  pass "missing ledger: exits 0"
else
  fail "missing ledger: expected exit 0, got $s8_status ($s8_out)"
fi

s8_line1="$(printf '%s\n' "$s8_out" | sed -n '1p')"
s8_line3="$(printf '%s\n' "$s8_out" | sed -n '3p')"
if printf '%s' "$s8_line1" | grep -q "learned 0"; then
  pass "missing ledger: line1 reports learned 0"
else
  fail "missing ledger: line1 mismatch, got [$s8_line1]"
fi
if [ "$s8_line3" = "learn-sweep: cursor 0 → 0 (0 new lines)" ]; then
  pass "missing ledger: line3 cursor 0 -> 0"
else
  fail "missing ledger: line3 mismatch, got [$s8_line3]"
fi

# =============================================================================
# Scenario 9: arg error — missing --data-dir exits 2.
# =============================================================================

STORE9="$(fresh_store s9)"
"$LEARN_SWEEP" "$STORE9" >/dev/null 2>&1
s9_status=$?
if [ "$s9_status" -eq 2 ]; then
  pass "missing --data-dir: exits 2"
else
  fail "missing --data-dir: expected exit 2, got $s9_status"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
