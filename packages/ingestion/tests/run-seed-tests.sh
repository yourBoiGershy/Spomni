#!/usr/bin/env bash
# packages/ingestion/tests/run-seed-tests.sh
#
# Regression-locks packages/ingestion/scripts/derive-participation.sh (U7)
# and packages/ingestion/scripts/suggest-tiers.sh (U8) against
# packages/ingestion/tests/fixtures/onboarding-seed/, per plan 24 unit 12.
# Same style as packages/connectors/tests/run-capture-tests.sh: numbered
# assertions via pass()/fail(), a SUMMARY line, non-zero exit on any
# failure. bash 3.2 portable (no associative arrays, no mapfile).
#
# Two fixture groups, deliberately split by which layer they exercise:
#
#   fixtures/onboarding-seed/participation-store/  — a real store (inbox/,
#     archive/raw/, interactions/, stats.json) run through
#     derive-participation.sh for real, exercising the gmail archive/raw
#     self-authorship path, the beeper embedded-body fallback path (no
#     archive/raw file — see cap-beeper-fallback.md), group_linked via
#     participant-hints, in-window filtering, and the config's fail-closed
#     posture with zero `self` rows.
#
#   fixtures/onboarding-seed/scoring/ — a hand-built stats.json +
#     participation.tsv pair fed directly to suggest-tiers.sh (bypassing
#     derive-participation.sh's file joins, which are already covered
#     above) to pin down the D3 scoring model itself: every base band
#     (including the exactly-21 warm tie), both boost deltas, the
#     cumulative clamp at 3, and all three chunk-20 example classes with
#     their exact relative order. expected-output.tsv is the literal,
#     byte-compared golden for that whole run.
#
# A third, on-the-fly-generated fixture (25 synthetic "filler" people, all
# forced to the same never-answered class by construction) exercises the
# cap-20 cut line — generated at run time rather than committed, since it's
# 25 near-identical rows differing only by an integer; the generation logic
# itself is inspectable right here.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DERIVE="$REPO_ROOT/packages/ingestion/scripts/derive-participation.sh"
SUGGEST="$REPO_ROOT/packages/ingestion/scripts/suggest-tiers.sh"
FIXTURES_DIR="$REPO_ROOT/packages/ingestion/tests/fixtures/onboarding-seed"
PARTICIPATION_STORE="$FIXTURES_DIR/participation-store"
SCORING_DIR="$FIXTURES_DIR/scoring"
CONFIG_WITH_SELF="$FIXTURES_DIR/config/with-self.tsv"
CONFIG_NO_SELF="$FIXTURES_DIR/config/no-self.tsv"

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

# --- scripts under test + fixtures must exist ---
if [ ! -x "$DERIVE" ]; then
  echo "FAIL: $DERIVE missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$SUGGEST" ]; then
  echo "FAIL: $SUGGEST missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$PARTICIPATION_STORE" ] || [ ! -d "$SCORING_DIR" ]; then
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

# =============================================================================
# Group 1 — derive-participation.sh, run for real against a real store.
# =============================================================================

# --- assertions 1-4: full-output byte comparison against a literal block ---
derive_out="$WORK_DIR/derive-out.tsv"
derive_err="$WORK_DIR/derive-err.txt"
"$DERIVE" "$PARTICIPATION_STORE" "$PARTICIPATION_STORE/stats.json" "2026-03-01" "$CONFIG_WITH_SELF" \
  > "$derive_out" 2> "$derive_err"
derive_status=$?

if [ "$derive_status" -eq 0 ]; then
  pass "derive-participation.sh: exits 0 against the participation-store fixture"
else
  fail "derive-participation.sh: exited $derive_status (expected 0): $(cat "$derive_err")"
fi

expected_derive="$WORK_DIR/expected-derive.tsv"
cat > "$expected_derive" <<'EOF'
beeper-engaged-fallback	1	0
gmail-engaged	1	0
gmail-inbound	0	1
window-filtered	0	0
EOF

if diff -q "$expected_derive" "$derive_out" >/dev/null 2>&1; then
  pass "derive-participation.sh: full output byte-identical to expected (gmail self-authored engaged, gmail group-linked inbound, beeper embedded-body-fallback engaged, in-window-filtered person defaults 0/0)"
else
  fail "derive-participation.sh: output mismatch — expected:
$(cat "$expected_derive")
got:
$(cat "$derive_out")"
fi

# --- assertion 5: gmail archive/raw self-authorship specifically ---
gmail_engaged_row="$(awk -F'\t' '$1 == "gmail-engaged"' "$derive_out")"
if [ "$gmail_engaged_row" = "$(printf 'gmail-engaged\t1\t0')" ]; then
  pass "gmail archive/raw path: self-authored sender -> user_engaged=1"
else
  fail "gmail archive/raw path: expected 'gmail-engaged\t1\t0', got '$gmail_engaged_row'"
fi

# --- assertion 6: gmail group_linked via participant-hints (>=3) ---
gmail_inbound_row="$(awk -F'\t' '$1 == "gmail-inbound"' "$derive_out")"
if [ "$gmail_inbound_row" = "$(printf 'gmail-inbound\t0\t1')" ]; then
  pass "gmail archive/raw path: 3 participant-hints -> group_linked=1, non-self sender -> user_engaged=0"
else
  fail "gmail archive/raw path: expected 'gmail-inbound\t0\t1', got '$gmail_inbound_row'"
fi

# --- assertion 7: beeper embedded-body fallback (no archive/raw file) ---
if [ -f "$PARTICIPATION_STORE/archive/raw/cap-beeper-fallback.json" ]; then
  fail "beeper fallback fixture: archive/raw/cap-beeper-fallback.json unexpectedly exists — fixture no longer exercises the fallback path"
else
  pass "beeper fallback fixture: no archive/raw file present (fallback path is actually exercised)"
fi

beeper_row="$(awk -F'\t' '$1 == "beeper-engaged-fallback"' "$derive_out")"
if [ "$beeper_row" = "$(printf 'beeper-engaged-fallback\t1\t0')" ]; then
  pass "beeper embedded-body fallback: isSender:true message -> user_engaged=1"
else
  fail "beeper embedded-body fallback: expected 'beeper-engaged-fallback\t1\t0', got '$beeper_row'"
fi

# --- assertion 8: in-window filtering — the out-of-window self-authored
# interaction must NOT flip user_engaged to 1 ---
window_row="$(awk -F'\t' '$1 == "window-filtered"' "$derive_out")"
if [ "$window_row" = "$(printf 'window-filtered\t0\t0')" ]; then
  pass "in-window filtering: out-of-window self-authored interaction contributes nothing (user_engaged stays 0)"
else
  fail "in-window filtering: expected 'window-filtered\t0\t0' (out-of-window signal must be ignored), got '$window_row'"
fi

# --- assertion 9: zero-self config fails closed ---
noself_out="$WORK_DIR/derive-noself-out.tsv"
noself_err="$WORK_DIR/derive-noself-err.txt"
"$DERIVE" "$PARTICIPATION_STORE" "$PARTICIPATION_STORE/stats.json" "2026-03-01" "$CONFIG_NO_SELF" \
  > "$noself_out" 2> "$noself_err"
noself_status=$?

if [ "$noself_status" -ne 0 ]; then
  pass "derive-participation.sh: zero-self config exits non-zero (fail-closed)"
else
  fail "derive-participation.sh: zero-self config exited 0 (expected non-zero, fail-closed)"
fi

if [ -s "$noself_err" ]; then
  pass "derive-participation.sh: zero-self config prints a non-empty stderr reason"
else
  fail "derive-participation.sh: zero-self config produced no stderr diagnostic"
fi

if [ ! -s "$noself_out" ]; then
  pass "derive-participation.sh: zero-self config produces no stdout"
else
  fail "derive-participation.sh: zero-self config unexpectedly produced stdout: $(cat "$noself_out")"
fi

# =============================================================================
# Group 2 — suggest-tiers.sh, fed a hand-built stats.json + participation.tsv
# directly (D3 scoring model coverage).
# =============================================================================

scoring_out="$WORK_DIR/scoring-out.tsv"
scoring_err="$WORK_DIR/scoring-err.txt"
"$SUGGEST" "$SCORING_DIR/stats.json" "$SCORING_DIR/participation.tsv" "2026-01-01" \
  > "$scoring_out" 2> "$scoring_err"
scoring_status=$?

if [ "$scoring_status" -eq 0 ]; then
  pass "suggest-tiers.sh: exits 0 against the scoring fixture"
else
  fail "suggest-tiers.sh: exited $scoring_status (expected 0): $(cat "$scoring_err")"
fi

# --- assertion: gate exclusion — gate-excluded (touchpoints=1) must not
# appear anywhere in the output ---
if grep -q '^gate-excluded' "$scoring_out"; then
  fail "gate: 'gate-excluded' (touchpoints=1) appeared in suggest-tiers.sh output — insufficient-data gate not applied"
else
  pass "gate: 'gate-excluded' (touchpoints=1) correctly excluded from output entirely"
fi

# --- assertion: full-output byte comparison against the literal golden —
# covers every base band (inner-circle/close/active/dormant), the exact-21
# warm tie, both boost deltas individually, the cumulative clamp at 3, all
# four breakdown-string variants present in this model (both-boosts,
# single-boost x2, both penalty renderings), and the three chunk-20 example
# classes' exact relative order in one shot ---
if diff -q "$SCORING_DIR/expected-output.tsv" "$scoring_out" >/dev/null 2>&1; then
  pass "suggest-tiers.sh: full scoring-fixture output byte-identical to expected-output.tsv"
else
  fail "suggest-tiers.sh: scoring-fixture output mismatch —
$(diff "$SCORING_DIR/expected-output.tsv" "$scoring_out")"
fi

# --- assertion: chunk-20 ordering — never-answered strictly last, silent-
# group ranked above it, the boosted active thread at/near the top (i.e.
# not below either penalty row) ---
last_slug="$(tail -n 1 "$scoring_out" | cut -f1)"
if [ "$last_slug" = "dormant95-never" ]; then
  pass "chunk-20 ordering: never-answered (VERY-LOW) person ranked strictly last"
else
  fail "chunk-20 ordering: expected 'dormant95-never' last, got '$last_slug' last"
fi

silent_line_no="$(grep -n '^active90-silent' "$scoring_out" | cut -d: -f1)"
never_line_no="$(grep -n '^dormant95-never' "$scoring_out" | cut -d: -f1)"
if [ -n "$silent_line_no" ] && [ -n "$never_line_no" ] && [ "$silent_line_no" -lt "$never_line_no" ]; then
  pass "chunk-20 ordering: silent-group (LOW) ranked above never-answered (VERY-LOW)"
else
  fail "chunk-20 ordering: expected silent-group above never-answered (lines $silent_line_no vs $never_line_no)"
fi

active_boosted_line_no="$(grep -n '^active-boosted' "$scoring_out" | cut -d: -f1)"
if [ -n "$active_boosted_line_no" ] && [ -n "$silent_line_no" ] && [ "$active_boosted_line_no" -lt "$silent_line_no" ]; then
  pass "chunk-20 ordering: boosted active thread ranked above both penalty classes (at/near top)"
else
  fail "chunk-20 ordering: expected 'active-boosted' above the penalty rows (lines $active_boosted_line_no vs $silent_line_no)"
fi

# --- note on breakdown coverage: "signals: none" is a defensive branch in
# suggest-tiers.sh (documented in its own header comment) that is
# structurally unreachable under the D3 model as specified — silent-group
# and never-answered exhaustively partition every case where both boosts
# are absent, so the "no boosts, no penalty" state this branch guards
# against can never actually occur through this script's own inputs. The
# four reachable breakdown variants (both-boosts: clamp-case; single-boost
# user-engaged: tie21/active-boosted; single-boost co-attended: close45;
# both penalty renderings: active90-silent/dormant95-never) are all
# byte-compared above via expected-output.tsv. This assertion instead
# regression-locks that the dead branch's literal string hasn't silently
# been dropped from the script, in case the model is ever relaxed to make
# it reachable.
if grep -qF 'signals: none' "$SUGGEST"; then
  pass "suggest-tiers.sh: 'signals: none' fallback branch still present in source (documented-unreachable under the current D3 model; see comment above)"
else
  fail "suggest-tiers.sh: 'signals: none' fallback branch missing from source"
fi

# =============================================================================
# Cap-20 cut line — generated on the fly (25 near-identical filler people,
# same never-answered class by construction, distinct median_gap_days so
# the cut is unambiguous).
# =============================================================================

cap_stats="$WORK_DIR/cap-stats.json"
cap_part="$WORK_DIR/cap-participation.tsv"

{
  echo '{'
  echo '  "schema_version": "1.0.0",'
  echo '  "generated_at": "2026-08-29T00:00:00Z",'
  echo '  "people": {'
  i=1
  while [ "$i" -le 25 ]; do
    gap=$((90 + i))
    slug="$(printf 'filler-%02d' "$i")"
    comma=","
    [ "$i" -eq 25 ] && comma=""
    printf '    "%s": {"tier": null, "touchpoints": 2, "median_gap_days": %d, "interactions": []}%s\n' \
      "$slug" "$gap" "$comma"
    i=$((i + 1))
  done
  echo '  }'
  echo '}'
} > "$cap_stats"

: > "$cap_part"
i=1
while [ "$i" -le 25 ]; do
  slug="$(printf 'filler-%02d' "$i")"
  printf '%s\t0\t0\n' "$slug" >> "$cap_part"
  i=$((i + 1))
done

cap_out="$WORK_DIR/cap-out.tsv"
cap_err="$WORK_DIR/cap-err.txt"
"$SUGGEST" "$cap_stats" "$cap_part" "2026-01-01" > "$cap_out" 2> "$cap_err"
cap_status=$?

if [ "$cap_status" -eq 0 ]; then
  pass "suggest-tiers.sh: exits 0 against the 25-person cap-20 fixture"
else
  fail "suggest-tiers.sh: cap-20 fixture exited $cap_status (expected 0): $(cat "$cap_err")"
fi

cap_row_count="$(wc -l < "$cap_out" | tr -d ' ')"
if [ "$cap_row_count" = "20" ]; then
  pass "cap-20: 25 gate-clearing people -> exactly 20 rows presented"
else
  fail "cap-20: expected exactly 20 rows, got $cap_row_count"
fi

expected_cap="$WORK_DIR/expected-cap.tsv"
: > "$expected_cap"
i=1
while [ "$i" -le 20 ]; do
  gap=$((90 + i))
  slug="$(printf 'filler-%02d' "$i")"
  printf '%s\t-1\tdormant\tsuggested: dormant | base: dormant (median_gap_days=%d) | class: never-answered (very low)\n' \
    "$slug" "$gap" >> "$expected_cap"
  i=$((i + 1))
done

if diff -q "$expected_cap" "$cap_out" >/dev/null 2>&1; then
  pass "cap-20: kept rows are exactly filler-01..filler-20 in ascending median_gap_days order (correct cut line — filler-21..25 excluded)"
else
  fail "cap-20: cut-line/order mismatch —
$(diff "$expected_cap" "$cap_out")"
fi

# =============================================================================
# Determinism — two consecutive full runs, byte-identical.
# =============================================================================

derive_out2="$WORK_DIR/derive-out2.tsv"
"$DERIVE" "$PARTICIPATION_STORE" "$PARTICIPATION_STORE/stats.json" "2026-03-01" "$CONFIG_WITH_SELF" \
  > "$derive_out2" 2>/dev/null

if diff -q "$derive_out" "$derive_out2" >/dev/null 2>&1; then
  pass "determinism: derive-participation.sh byte-identical across two consecutive runs"
else
  fail "determinism: derive-participation.sh output differed across two runs"
fi

scoring_out2="$WORK_DIR/scoring-out2.tsv"
"$SUGGEST" "$SCORING_DIR/stats.json" "$SCORING_DIR/participation.tsv" "2026-01-01" \
  > "$scoring_out2" 2>/dev/null

if diff -q "$scoring_out" "$scoring_out2" >/dev/null 2>&1; then
  pass "determinism: suggest-tiers.sh byte-identical across two consecutive runs"
else
  fail "determinism: suggest-tiers.sh output differed across two runs"
fi

# =============================================================================
# Read-only proof — neither script may write anywhere under the fixture
# store or the fixtures dir.
# =============================================================================

sentinel="$WORK_DIR/sentinel"
touch "$sentinel"
sleep 1
"$DERIVE" "$PARTICIPATION_STORE" "$PARTICIPATION_STORE/stats.json" "2026-03-01" "$CONFIG_WITH_SELF" \
  >/dev/null 2>&1
"$SUGGEST" "$SCORING_DIR/stats.json" "$SCORING_DIR/participation.tsv" "2026-01-01" \
  >/dev/null 2>&1

touched="$(find "$FIXTURES_DIR" -newer "$sentinel" -print 2>/dev/null)"
if [ -z "$touched" ]; then
  pass "read-only: neither script wrote anywhere under fixtures/onboarding-seed/"
else
  fail "read-only: unexpected writes under fixtures/onboarding-seed/: $touched"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
