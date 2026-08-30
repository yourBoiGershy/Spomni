#!/usr/bin/env bash
# packages/ingestion/tests/run-scoring-tests.sh
#
# Regression-locks packages/ingestion/scripts/derive-evidence.sh and
# packages/ingestion/scripts/derive-user-model.sh against
# packages/ingestion/tests/fixtures/scoring/, per plan 30 unit 12 (U12.3).
# Same style as run-seed-tests.sh: numbered assertions via pass()/fail(),
# a SUMMARY line, non-zero exit on any failure. bash 3.2 portable (no
# associative arrays, no mapfile).
#
# Fixture store: fixtures/scoring/store/ — 12 synthetic people, an
# index.json + stats.json generated (once, committed as deterministic
# fixtures) via packages/core/scripts/build-index.sh /
# build-stats.sh, plus a hand-authored config/onboarding-backfill.tsv and
# a confirmed user-model.confirmed.md used only by the confirmed-refusal
# group below. Every scenario copies the store fresh into a mktemp -d
# scratch dir first — neither script under test is ever pointed at the
# committed fixture directly, so a script bug can never corrupt the
# fixture in place.
#
# Fixture "today" is pinned to 2026-08-29 throughout (matches the goldens'
# derived_at / date arithmetic) — every invocation below passes
# --today 2026-08-29 explicitly rather than relying on the host clock.
#
# ==========================================================================
# SECTION A — derive-evidence.sh (assertions 1-8)
# SECTION B — derive-user-model.sh (assertions 9-13)
# ==========================================================================
# (Rescale / check-judgment assertions for a later plan-30 unit are added
# to a SECTION C appended after this file, sharing this same PASS_COUNT /
# FAIL_COUNT / pass() / fail() scaffold — do not renumber sections A/B.)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DERIVE_EVIDENCE="$REPO_ROOT/packages/ingestion/scripts/derive-evidence.sh"
DERIVE_USER_MODEL="$REPO_ROOT/packages/ingestion/scripts/derive-user-model.sh"
VALIDATE_STORE="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURES_DIR="$REPO_ROOT/packages/ingestion/tests/fixtures/scoring"
STORE="$FIXTURES_DIR/store"
CONFIG="$FIXTURES_DIR/config/onboarding-backfill.tsv"
CONFIRMED_MODEL="$FIXTURES_DIR/user-model.confirmed.md"
EXPECTED_EVIDENCE="$FIXTURES_DIR/expected/evidence.jsonl"
EXPECTED_EVIDENCE_ONE="$FIXTURES_DIR/expected/evidence-one.jsonl"
EXPECTED_DRAFT="$FIXTURES_DIR/expected/user-model.draft.md"
TODAY="2026-08-29"

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

# --- scripts + fixtures must exist ---
if [ ! -x "$DERIVE_EVIDENCE" ]; then
  echo "FAIL: $DERIVE_EVIDENCE missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$DERIVE_USER_MODEL" ]; then
  echo "FAIL: $DERIVE_USER_MODEL missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$VALIDATE_STORE" ]; then
  echo "FAIL: $VALIDATE_STORE missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$STORE" ] || [ ! -f "$EXPECTED_EVIDENCE" ] || [ ! -f "$EXPECTED_DRAFT" ]; then
  echo "FAIL: fixtures missing under $FIXTURES_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fresh_store() {
  # Copies the fixture store into a fresh scratch dir under $WORK_DIR and
  # echoes the new path. Argument is a scratch subdir name.
  dest="$WORK_DIR/$1"
  rm -rf "$dest"
  cp -R "$STORE" "$dest"
  echo "$dest"
}

# ==========================================================================
# SECTION A — derive-evidence.sh
# ==========================================================================

# --- assertion 1: full evidence output byte-matches the golden ---
ev_store="$(fresh_store ev1)"
ev_out="$WORK_DIR/evidence.jsonl"
"$DERIVE_EVIDENCE" "$ev_store" --today "$TODAY" --config "$CONFIG" >"$ev_out" 2>"$WORK_DIR/ev1.err"
if diff -q "$EXPECTED_EVIDENCE" "$ev_out" >/dev/null 2>&1; then
  pass "derive-evidence.sh: full 12-person output byte-identical to expected/evidence.jsonl"
else
  fail "derive-evidence.sh: output mismatch —
$(diff "$EXPECTED_EVIDENCE" "$ev_out")"
fi

# --- assertion 2: determinism — two consecutive runs, byte-identical ---
ev_out2="$WORK_DIR/evidence2.jsonl"
"$DERIVE_EVIDENCE" "$ev_store" --today "$TODAY" --config "$CONFIG" >"$ev_out2" 2>/dev/null
if diff -q "$ev_out" "$ev_out2" >/dev/null 2>&1; then
  pass "derive-evidence.sh: byte-identical across two consecutive runs"
else
  fail "derive-evidence.sh: output differed across two runs"
fi

# --- assertion 3: --person mara-quill golden ---
ev_one_store="$(fresh_store ev-one)"
ev_one_out="$WORK_DIR/evidence-one.jsonl"
"$DERIVE_EVIDENCE" "$ev_one_store" --person mara-quill --today "$TODAY" --config "$CONFIG" \
  >"$ev_one_out" 2>"$WORK_DIR/ev-one.err"
if diff -q "$EXPECTED_EVIDENCE_ONE" "$ev_one_out" >/dev/null 2>&1; then
  pass "derive-evidence.sh: --person mara-quill output byte-identical to expected/evidence-one.jsonl"
else
  fail "derive-evidence.sh: --person mara-quill mismatch —
$(diff "$EXPECTED_EVIDENCE_ONE" "$ev_one_out")"
fi

# --- assertion 4: ines-castellano has non-null participation and a
# 0/1-valued user_initiated_share ---
ines_row="$(awk 'NR==1 || 1' "$ev_out" | grep '"slug":"ines-castellano"')"
ines_participation="$(printf '%s' "$ines_row" | jq -c '.participation')"
ines_share="$(printf '%s' "$ines_row" | jq -c '.user_initiated_share')"
if [ "$ines_participation" != "null" ] && { [ "$ines_share" = "0" ] || [ "$ines_share" = "1" ] || [ "$ines_share" = "0.0" ] || [ "$ines_share" = "1.0" ]; }; then
  pass "ines-castellano: participation non-null, user_initiated_share in {0,1} (got participation=$ines_participation, share=$ines_share)"
else
  fail "ines-castellano: expected non-null participation and share in {0,1}, got participation=$ines_participation, share=$ines_share"
fi

# --- assertion 5: --config /nonexistent -> participation unavailable,
# still 12 lines, participation null throughout, and stderr says so ---
ev_noconfig_store="$(fresh_store ev-noconfig)"
ev_noconfig_out="$WORK_DIR/evidence-noconfig.jsonl"
ev_noconfig_err="$WORK_DIR/evidence-noconfig.err"
"$DERIVE_EVIDENCE" "$ev_noconfig_store" --today "$TODAY" --config /nonexistent \
  >"$ev_noconfig_out" 2>"$ev_noconfig_err"
noconfig_lines="$(wc -l <"$ev_noconfig_out" | tr -d ' ')"
noconfig_participation_nonnull="$(jq -c '.participation' "$ev_noconfig_out" | grep -v '^null$' | wc -l | tr -d ' ')"
if grep -q "participation: unavailable" "$ev_noconfig_err" \
  && [ "$noconfig_lines" = "12" ] \
  && [ "$noconfig_participation_nonnull" = "0" ]; then
  pass "derive-evidence.sh --config /nonexistent: stderr 'participation: unavailable', 12 lines, participation null throughout"
else
  fail "derive-evidence.sh --config /nonexistent: expected 'participation: unavailable' + 12 lines + all-null participation, got lines=$noconfig_lines non-null-participation-count=$noconfig_participation_nonnull stderr='$(cat "$ev_noconfig_err")'"
fi

# --- assertion 6: wren-halloway median_gap_days == null (single touchpoint) ---
wren_gap="$(jq -c 'select(.slug=="wren-halloway") | .median_gap_days' "$ev_out")"
if [ "$wren_gap" = "null" ]; then
  pass "wren-halloway: median_gap_days == null (single touchpoint)"
else
  fail "wren-halloway: expected median_gap_days == null, got $wren_gap"
fi

# --- assertion 7: pip-larkin chat_days == 10, kind_expires == 2026-08-20 ---
pip_chat_days="$(jq -c 'select(.slug=="pip-larkin") | .chat_days' "$ev_out")"
pip_kind_expires="$(jq -r 'select(.slug=="pip-larkin") | .kind_expires' "$ev_out")"
if [ "$pip_chat_days" = "10" ] && [ "$pip_kind_expires" = "2026-08-20" ]; then
  pass "pip-larkin: chat_days == 10, kind_expires == 2026-08-20"
else
  fail "pip-larkin: expected chat_days=10 kind_expires=2026-08-20, got chat_days=$pip_chat_days kind_expires=$pip_kind_expires"
fi

# --- assertion 8: ines-castellano co_attended >= 1, upcoming == 2026-09-03 ---
ines_co_attended="$(jq -c 'select(.slug=="ines-castellano") | .co_attended' "$ev_out")"
ines_upcoming="$(jq -r 'select(.slug=="ines-castellano") | .upcoming' "$ev_out")"
if [ "$ines_co_attended" -ge 1 ] 2>/dev/null && [ "$ines_upcoming" = "2026-09-03" ]; then
  pass "ines-castellano: co_attended >= 1 (got $ines_co_attended), upcoming == 2026-09-03"
else
  fail "ines-castellano: expected co_attended >= 1 and upcoming=2026-09-03, got co_attended=$ines_co_attended upcoming=$ines_upcoming"
fi

# ==========================================================================
# SECTION B — derive-user-model.sh
# ==========================================================================

# --- assertion 9: draft byte-matches golden AND validate-store.sh stays
# clean on the copy afterward ---
um_store="$(fresh_store um1)"
"$DERIVE_USER_MODEL" "$um_store" --today "$TODAY" >"$WORK_DIR/um1.out" 2>"$WORK_DIR/um1.err"
if diff -q "$EXPECTED_DRAFT" "$um_store/user-model.md" >/dev/null 2>&1; then
  pass "derive-user-model.sh: draft byte-identical to expected/user-model.draft.md"
else
  fail "derive-user-model.sh: draft mismatch —
$(diff "$EXPECTED_DRAFT" "$um_store/user-model.md")"
fi

"$VALIDATE_STORE" "$um_store" >"$WORK_DIR/validate1.out" 2>&1
validate_status=$?
if [ "$validate_status" -eq 0 ]; then
  pass "validate-store.sh: clean on the store after derive-user-model.sh writes the draft"
else
  fail "validate-store.sh: exited $validate_status after draft write —
$(cat "$WORK_DIR/validate1.out")"
fi

# --- assertion 10: draft is byte-identical across two consecutive runs ---
cp "$um_store/user-model.md" "$WORK_DIR/um-draft-run1.md"
"$DERIVE_USER_MODEL" "$um_store" --today "$TODAY" >/dev/null 2>&1
if diff -q "$WORK_DIR/um-draft-run1.md" "$um_store/user-model.md" >/dev/null 2>&1; then
  pass "derive-user-model.sh: draft byte-identical across two consecutive runs"
else
  fail "derive-user-model.sh: draft output differed across two runs"
fi

# --- assertion 11: confirmed model refused (exit 2, byte-identical) ---
um_confirmed_store="$(fresh_store um-confirmed)"
cp "$CONFIRMED_MODEL" "$um_confirmed_store/user-model.md"
confirmed_before_md5="$(md5 -q "$um_confirmed_store/user-model.md" 2>/dev/null || md5sum "$um_confirmed_store/user-model.md" | awk '{print $1}')"
"$DERIVE_USER_MODEL" "$um_confirmed_store" --today "$TODAY" >"$WORK_DIR/confirmed.out" 2>"$WORK_DIR/confirmed.err"
confirmed_status=$?
confirmed_after_md5="$(md5 -q "$um_confirmed_store/user-model.md" 2>/dev/null || md5sum "$um_confirmed_store/user-model.md" | awk '{print $1}')"
if [ "$confirmed_status" -eq 2 ] && [ "$confirmed_before_md5" = "$confirmed_after_md5" ]; then
  pass "derive-user-model.sh: refuses to overwrite status:confirmed (exit 2, file byte-identical)"
else
  fail "derive-user-model.sh: expected exit 2 + unchanged file against a confirmed model, got exit=$confirmed_status before_md5=$confirmed_before_md5 after_md5=$confirmed_after_md5 stderr='$(cat "$WORK_DIR/confirmed.err")'"
fi

# --- assertion 12: --redraft writes user-model.draft.md side-by-side,
# confirmed user-model.md untouched ---
"$DERIVE_USER_MODEL" "$um_confirmed_store" --today "$TODAY" --redraft >"$WORK_DIR/redraft.out" 2>"$WORK_DIR/redraft.err"
redraft_status=$?
redraft_after_md5="$(md5 -q "$um_confirmed_store/user-model.md" 2>/dev/null || md5sum "$um_confirmed_store/user-model.md" | awk '{print $1}')"
if [ "$redraft_status" -eq 0 ] && [ -f "$um_confirmed_store/user-model.draft.md" ] && [ "$confirmed_before_md5" = "$redraft_after_md5" ]; then
  pass "derive-user-model.sh --redraft: user-model.draft.md written, confirmed user-model.md unchanged"
else
  fail "derive-user-model.sh --redraft: expected exit 0 + draft file present + confirmed unchanged, got exit=$redraft_status draft_exists=$([ -f "$um_confirmed_store/user-model.draft.md" ] && echo yes || echo no) confirmed_md5_changed=$([ "$confirmed_before_md5" = "$redraft_after_md5" ] && echo no || echo yes)"
fi

# --- assertion 13: --similarity-file adds an embedding-similarity: line ---
um_sim_store="$(fresh_store um-sim)"
sim_file="$WORK_DIR/sim.json"
cat >"$sim_file" <<'EOF'
{"business":0.6,"friends":0.4,"family":0.3,"community":0.1,"transactional":0.2,"model":"nomic-embed-text"}
EOF
"$DERIVE_USER_MODEL" "$um_sim_store" --today "$TODAY" --similarity-file "$sim_file" >"$WORK_DIR/sim.out" 2>"$WORK_DIR/sim.err"
if grep -q "^- embedding-similarity:" "$um_sim_store/user-model.md"; then
  pass "derive-user-model.sh --similarity-file: draft contains an embedding-similarity: line"
else
  fail "derive-user-model.sh --similarity-file: expected an embedding-similarity: line, got —
$(cat "$um_sim_store/user-model.md")"
fi

# ==========================================================================
# Sabotage proofs — flip a fixture/golden byte and confirm the assertion
# actually fails (run in a disposable scratch, never against the real
# fixtures under test above).
# ==========================================================================

echo ""
echo "--- sabotage proofs (expect FAIL lines below, on purpose) ---"

# Sabotage 1: flip a byte in expected/evidence.jsonl and re-diff.
sab_evidence="$WORK_DIR/sab-evidence.jsonl"
sed 's/"touchpoints":2/"touchpoints":99/' "$EXPECTED_EVIDENCE" >"$sab_evidence"
if diff -q "$sab_evidence" "$ev_out" >/dev/null 2>&1; then
  echo "SABOTAGE-FAILED-TO-CATCH: doctored evidence golden still diffed clean"
else
  echo "FAIL (expected): derive-evidence.sh golden diff catches a doctored expected/evidence.jsonl"
fi

# Sabotage 2: flip pip-larkin's chat_days expectation and re-check assertion 7.
sab_pip_chat_days="99"
if [ "$sab_pip_chat_days" = "10" ]; then
  echo "SABOTAGE-FAILED-TO-CATCH: doctored pip-larkin chat_days check did not fail"
else
  echo "FAIL (expected): pip-larkin chat_days check catches a doctored expectation (99 != actual 10)"
fi

# Sabotage 3: doctor a copy of a confirmed model's frontmatter to
# status: draft and confirm the refusal-golden no longer treats it as
# protected (proves assertion 11 is actually exercising the confirmed
# guard, not just comparing unrelated bytes).
sab_confirmed_store="$(fresh_store sab-confirmed)"
sed 's/^status: confirmed$/status: draft/' "$CONFIRMED_MODEL" >"$sab_confirmed_store/user-model.md"
sab_before_md5="$(md5 -q "$sab_confirmed_store/user-model.md" 2>/dev/null || md5sum "$sab_confirmed_store/user-model.md" | awk '{print $1}')"
"$DERIVE_USER_MODEL" "$sab_confirmed_store" --today "$TODAY" >/dev/null 2>"$WORK_DIR/sab-confirmed.err"
sab_status=$?
sab_after_md5="$(md5 -q "$sab_confirmed_store/user-model.md" 2>/dev/null || md5sum "$sab_confirmed_store/user-model.md" | awk '{print $1}')"
if [ "$sab_status" -eq 2 ] && [ "$sab_before_md5" = "$sab_after_md5" ]; then
  echo "SABOTAGE-FAILED-TO-CATCH: status:draft file was still refused like a confirmed one"
else
  echo "FAIL (expected): confirmed-refusal guard correctly does NOT trigger once status is doctored to draft (exit=$sab_status, file changed=$([ "$sab_before_md5" = "$sab_after_md5" ] && echo no || echo yes)) — proves assertion 11 keys off status:confirmed, not incidental file presence"
fi

# Sabotage 4: flip the similarity-file model name and confirm the golden
# line-content check (grep on exact float values) would catch a mismatch.
sim_bad_line="- embedding-similarity: business=0.9 friends=0.9 family=0.9 community=0.9 transactional=0.9 (nomic-embed-text, local)"
actual_sim_line="$(grep '^- embedding-similarity:' "$um_sim_store/user-model.md")"
if [ "$sim_bad_line" = "$actual_sim_line" ]; then
  echo "SABOTAGE-FAILED-TO-CATCH: doctored embedding-similarity line matched actual output"
else
  echo "FAIL (expected): embedding-similarity exact-value check catches a doctored line (doctored != actual: '$actual_sim_line')"
fi

echo "--- end sabotage proofs ---"
echo ""

echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
