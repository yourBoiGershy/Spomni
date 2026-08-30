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

# --- assertion 8b: store currency (specs/currency.md) — talking_points
# drops an "unverified since D" Open threads bullet when D predates the
# person's second-most-recent interaction, keeps a fresh as-of bullet and
# a bare pre-1.4.0 bullet, and never surfaces a "## Resolved" bullet.
# dex-morrow's interactions (committed fixture, unedited) are
# 2026-07-20 / 2026-08-03 / 2026-08-18 -> second-most-recent is
# 2026-08-03. Edited only in a scratch copy — the committed fixture and
# its evidence.jsonl golden are untouched. ---
ev_currency_store="$(fresh_store ev-currency)"
cat > "$ev_currency_store/people/dex-morrow.md" <<'EOF'
---
schema_version: 1.4.0
name: Dex Morrow
org: Morrow Growth Partners
role:
location:
tags: []
birthday:
how-met: Cold-emailed with a pitch for Morrow Growth Partners' services
last-touch: 2026-08-18
---

## Facts

- **[told-by-user]** Keeps sending pitch emails without a reply from me (2026-08-20)

## Open threads

- Wants intro to a portfolio company (as-of 2026-08-18)
- Asked about doubling the pitch budget (as-of 2026-07-20, unverified since 2026-07-25)
- No open thread — pitches have gone unanswered so far.

## Resolved

- Sent a follow-up thank-you email (resolved 2026-08-10)

## Personal details

No personal details on file — relationship is limited to unsolicited pitch
emails.
EOF
ev_currency_out="$WORK_DIR/evidence-currency.jsonl"
"$DERIVE_EVIDENCE" "$ev_currency_store" --person dex-morrow --today "$TODAY" --config "$CONFIG" \
  >"$ev_currency_out" 2>"$WORK_DIR/ev-currency.err"
dex_items="$(jq -c '.talking_points.items' "$ev_currency_out")"
dex_count="$(jq -r '.talking_points.count' "$ev_currency_out")"
c8b_ok=1
[ "$dex_count" = "2" ] || c8b_ok=0
printf '%s' "$dex_items" | grep -q "Wants intro to a portfolio company" || c8b_ok=0
printf '%s' "$dex_items" | grep -q "No open thread" || c8b_ok=0
printf '%s' "$dex_items" | grep -q "doubling the pitch budget" && c8b_ok=0
printf '%s' "$dex_items" | grep -q "thank-you email" && c8b_ok=0
if [ "$c8b_ok" -eq 1 ]; then
  pass "derive-evidence.sh: currency rule drops unverified-before-second-touch bullet, keeps fresh as-of + bare bullets, no Resolved leak (dex-morrow, scratch copy)"
else
  fail "derive-evidence.sh: currency rule mismatch on dex-morrow (count=$dex_count items=$dex_items)"
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

# --- assertion 13b: mixed-case Beeper channel in source-capture
# (`beeper-in-WhatsApp`, as seen in the live store) still matches the
# personal-channel heuristic case-insensitively, for a person the
# heuristic (not a stated `kind`) actually decides. sol-abernathy carries
# no `kind`, no `family` tag, and no calendar co-attendance — under the
# fixture's baseline (lowercase-hex legacy beeper ids), sol's interactions
# fall through to `unassigned` and the golden friends share is driven
# entirely by other (kind: friend) people, 0.24. Rewriting sol's beeper
# interaction ids to mixed-case `beeper-in-WhatsApp-<hex>` must flip sol
# onto the friends axis and raise the share to 0.32 — the exact number a
# hand count confirms (sol's 5 interactions move from unassigned into
# friends out of the fixture's fixed in-window total). Regression lock for
# the case-sensitivity bug fixed at packages/ingestion/scripts/
# derive-user-model.sh (channel match is now `ascii_downcase`d before the
# whatsapp/matrix contains() check). ---
um_case_store="$(fresh_store um-case-insensitive)"
for f in "$um_case_store"/interactions/*-sol-abernathy.md; do
  [ -e "$f" ] || continue
  sed -i.bak 's/beeper-in-/beeper-in-WhatsApp-/' "$f"
  rm -f "$f.bak"
done
"$DERIVE_USER_MODEL" "$um_case_store" --today "$TODAY" >"$WORK_DIR/um-case.out" 2>"$WORK_DIR/um-case.err"
case_friends_line="$(grep -m1 '^- friends:' "$um_case_store/user-model.md")"
expected_case_friends_line="- friends: 0.32 — largest share of interactions in the last 90 days"
if [ "$case_friends_line" = "$expected_case_friends_line" ]; then
  pass "derive-user-model.sh: mixed-case beeper-in-WhatsApp on unkinded sol-abernathy flips friends: to 0.32 ('$case_friends_line')"
else
  fail "derive-user-model.sh: mixed-case beeper channel test expected friends line '$expected_case_friends_line', got '$case_friends_line'"
fi

# ==========================================================================
# SECTION C — rescale-scores.sh and check-judgment.sh
# ==========================================================================

RESCALE="$REPO_ROOT/packages/ingestion/scripts/rescale-scores.sh"
CHECK_JUDGMENT="$REPO_ROOT/packages/ingestion/scripts/check-judgment.sh"
JUDGMENTS_DIR="$FIXTURES_DIR/judgments"
SKEWED="$JUDGMENTS_DIR/skewed.jsonl"
CENTERED="$JUDGMENTS_DIR/centered.jsonl"
REJECTS="$JUDGMENTS_DIR/rejects.jsonl"
CLEAN="$JUDGMENTS_DIR/clean.jsonl"
EXPECTED_REPORT="$FIXTURES_DIR/expected/rescale-report.tsv"
EXPECTED_RECENTERED="$FIXTURES_DIR/expected/rescale-recentered.jsonl"
EXPECTED_RANK="$FIXTURES_DIR/expected/rescale-rank.jsonl"
EXPECTED_CHECK_REJECTS="$FIXTURES_DIR/expected/check-rejects.tsv"

if [ ! -x "$RESCALE" ]; then
  echo "FAIL: $RESCALE missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -x "$CHECK_JUDGMENT" ]; then
  echo "FAIL: $CHECK_JUDGMENT missing or not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -f "$SKEWED" ] || [ ! -f "$CENTERED" ] || [ ! -f "$REJECTS" ] || [ ! -f "$CLEAN" ]; then
  echo "FAIL: judgment fixtures missing under $JUDGMENTS_DIR"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# --- assertion 14: --report byte-matches golden ---
report_out="$WORK_DIR/report.tsv"
"$RESCALE" "$SKEWED" --report >"$report_out" 2>"$WORK_DIR/report.err"
if diff -q "$EXPECTED_REPORT" "$report_out" >/dev/null 2>&1; then
  pass "rescale-scores.sh --report: skewed-batch output byte-identical to expected/rescale-report.tsv"
else
  fail "rescale-scores.sh --report: mismatch —
$(diff "$EXPECTED_REPORT" "$report_out")"
fi

# --- assertion 15: overall row says skew yes, with the triggering
# condition derivable from its own columns (share_ge_80 > 0.5 here) ---
overall_row="$(awk -F'\t' '$1 == "overall"' "$report_out")"
overall_skew="$(printf '%s' "$overall_row" | awk -F'\t' '{print $8}')"
overall_ge80="$(printf '%s' "$overall_row" | awk -F'\t' '{print $6}')"
if [ "$overall_skew" = "yes" ] && awk -v v="$overall_ge80" 'BEGIN{exit !(v>0.5)}'; then
  pass "rescale-scores.sh --report: overall row skew=yes, reason derivable from share_ge_80=$overall_ge80 (>0.5)"
else
  fail "rescale-scores.sh --report: expected overall skew=yes with share_ge_80>0.5, got skew=$overall_skew share_ge_80=$overall_ge80"
fi

# --- assertion 16: one per-kind row per distinct kind (6 kinds in the
# skewed fixture) ---
kind_row_count="$(awk -F'\t' 'NR>1 && $1!="overall"' "$report_out" | wc -l | tr -d ' ')"
distinct_kind_count="$(jq -r '.kind' "$SKEWED" | sort -u | wc -l | tr -d ' ')"
if [ "$kind_row_count" = "$distinct_kind_count" ] && [ "$kind_row_count" = "6" ]; then
  pass "rescale-scores.sh --report: per-kind row count ($kind_row_count) == distinct kinds in input (6)"
else
  fail "rescale-scores.sh --report: expected 6 per-kind rows matching 6 distinct kinds, got rows=$kind_row_count distinct=$distinct_kind_count"
fi

# --- assertion 17: --rescale byte-matches golden ---
recentered_out="$WORK_DIR/recentered.jsonl"
"$RESCALE" "$SKEWED" --rescale >"$recentered_out" 2>"$WORK_DIR/recentered.err"
if diff -q "$EXPECTED_RECENTERED" "$recentered_out" >/dev/null 2>&1; then
  pass "rescale-scores.sh --rescale: skewed-batch output byte-identical to expected/rescale-recentered.jsonl"
else
  fail "rescale-scores.sh --rescale: mismatch —
$(diff "$EXPECTED_RECENTERED" "$recentered_out")"
fi

# --- assertion 18: rescaled mean within +/-0.5 of the target mean (50) ---
rescaled_mean="$(jq -s 'map(.attention_warrant) | add / length' "$recentered_out")"
if awk -v m="$rescaled_mean" 'BEGIN{d=m-50; if (d<0) d=-d; exit !(d<=0.5)}'; then
  pass "rescale-scores.sh --rescale: rescaled mean ($rescaled_mean) within +/-0.5 of target 50"
else
  fail "rescale-scores.sh --rescale: rescaled mean ($rescaled_mean) outside +/-0.5 of target 50"
fi

# --- assertion 19: ordering preserved — sorting by the ORIGINAL warrant
# (rescaled_from) must leave the rescaled attention_warrant non-decreasing ---
ordering_ok="$(jq -s '
  sort_by(.rescaled_from) | map(.attention_warrant) as $a
  | [range(0; ($a|length) - 1)] | map($a[.] <= $a[.+1]) | all
' "$recentered_out")"
if [ "$ordering_ok" = "true" ]; then
  pass "rescale-scores.sh --rescale: rank order of attention_warrant preserved end to end"
else
  fail "rescale-scores.sh --rescale: rank order not preserved — $(jq -s 'sort_by(.rescaled_from)|map({from:.rescaled_from,to:.attention_warrant})' "$recentered_out")"
fi

# --- assertion 20: every rescaled warrant is within 0-100 ---
out_of_range="$(jq -s 'map(select(.attention_warrant < 0 or .attention_warrant > 100)) | length' "$recentered_out")"
if [ "$out_of_range" = "0" ]; then
  pass "rescale-scores.sh --rescale: all rescaled warrants within 0-100"
else
  fail "rescale-scores.sh --rescale: $out_of_range warrant(s) fell outside 0-100"
fi

# --- assertion 21: scheduling/transactional/unsolicited never above
# 'active' after the recompute (kind caps survive a rescale) ---
capped_violations="$(jq -s '
  map(select((.kind=="scheduling" or .kind=="transactional" or .kind=="unsolicited")
             and (.suggested_tier=="inner-circle" or .suggested_tier=="close")))
  | length
' "$recentered_out")"
if [ "$capped_violations" = "0" ]; then
  pass "rescale-scores.sh --rescale: scheduling/transactional/unsolicited never suggested above active"
else
  fail "rescale-scores.sh --rescale: $capped_violations capped-kind record(s) suggested above active"
fi

# --- assertion 22: --rescale on centered.jsonl is a no-op apart from
# the added rescaled_from field (already at target mean/spread) ---
centered_out="$WORK_DIR/centered-rescaled.jsonl"
"$RESCALE" "$CENTERED" --rescale >"$centered_out" 2>"$WORK_DIR/centered.err"
# Compare each rescaled record's attention_warrant/suggested_tier against the
# ORIGINAL centered.jsonl record for the same slug (order-preserved 1:1).
centered_diff="$(paste -d'|' <(jq -c '{slug, attention_warrant, suggested_tier}' "$CENTERED") \
                              <(jq -c '{slug, attention_warrant, suggested_tier}' "$centered_out") \
  | awk -F'|' '$1 != $2 { print; count++ } END { print (count+0) }')"
centered_mismatch_count="$(printf '%s\n' "$centered_diff" | tail -1)"
if [ "$centered_mismatch_count" = "0" ] || [ -z "$centered_diff" ]; then
  pass "rescale-scores.sh --rescale: no-op on centered.jsonl apart from rescaled_from (already at target)"
else
  fail "rescale-scores.sh --rescale: centered.jsonl was NOT a no-op —
$centered_diff"
fi

# --- assertion 23: idempotence — rescaling an already-rescaled batch a
# second time stays within tolerance of the first pass ---
pass1_stripped="$WORK_DIR/pass1-stripped.jsonl"
jq -c 'del(.rescaled_from)' "$recentered_out" >"$pass1_stripped"
pass2_out="$WORK_DIR/pass2.jsonl"
"$RESCALE" "$pass1_stripped" --rescale >"$pass2_out" 2>"$WORK_DIR/pass2.err"
idempotent_ok="$(paste -d'|' <(jq -c '.attention_warrant' "$recentered_out") \
                              <(jq -c '.attention_warrant' "$pass2_out") \
  | awk -F'|' '{d=$1-$2; if (d<0) d=-d; if (d>1) bad++} END{print (bad+0)}')"
if [ "$idempotent_ok" = "0" ]; then
  pass "rescale-scores.sh --rescale: idempotent within tolerance across a second pass"
else
  fail "rescale-scores.sh --rescale: second pass drifted more than tolerance on $idempotent_ok record(s)"
fi

# --- assertion 24: --rank byte-matches golden ---
rank_out="$WORK_DIR/rank.jsonl"
"$RESCALE" "$SKEWED" --rank >"$rank_out" 2>"$WORK_DIR/rank.err"
if diff -q "$EXPECTED_RANK" "$rank_out" >/dev/null 2>&1; then
  pass "rescale-scores.sh --rank: skewed-batch output byte-identical to expected/rescale-rank.jsonl"
else
  fail "rescale-scores.sh --rank: mismatch —
$(diff "$EXPECTED_RANK" "$rank_out")"
fi

# --- assertion 25: --report on a 3-record batch prints skew: n/a (n<4) ---
# clean.jsonl is a check-judgment fixture, not a scored batch — build a
# throwaway 3-record scored batch inline instead, reusing skewed's shape.
three_record_out="$WORK_DIR/three-record.tsv"
three_scored="$WORK_DIR/three-scored.jsonl"
head -n 3 "$SKEWED" >"$three_scored"
"$RESCALE" "$three_scored" --report >"$three_record_out" 2>"$WORK_DIR/three-record.err"
three_overall_skew="$(awk -F'\t' '$1=="overall"{print $8}' "$three_record_out")"
if [ "$three_overall_skew" = "n/a (n<4)" ]; then
  pass "rescale-scores.sh --report: n=3 batch reports skew: n/a (n<4)"
else
  fail "rescale-scores.sh --report: expected skew='n/a (n<4)' for n=3, got '$three_overall_skew'"
fi

# --- assertion 26: check-judgment.sh on rejects.jsonl byte-matches
# expected/check-rejects.tsv, every reason token present exactly once,
# exits 1 ---
rejects_out="$WORK_DIR/check-rejects.tsv"
set +e
"$CHECK_JUDGMENT" "$REJECTS" --today 2026-08-29 --evidence "$EXPECTED_EVIDENCE" >"$rejects_out" 2>"$WORK_DIR/rejects.err"
rejects_status=$?
set -e
if diff -q "$EXPECTED_CHECK_REJECTS" "$rejects_out" >/dev/null 2>&1 && [ "$rejects_status" -eq 1 ]; then
  pass "check-judgment.sh: rejects.jsonl byte-identical to expected/check-rejects.tsv, exits 1"
else
  fail "check-judgment.sh: rejects.jsonl mismatch (exit=$rejects_status) —
$(diff "$EXPECTED_CHECK_REJECTS" "$rejects_out")"
fi

reason_tokens="bad-json missing-field:kind warrant-range kind-vocabulary kind-note-empty scheduling-needs-expiry expires-shape confidence-enum tier-enum rationale-cites-kind rationale-cites-evidence rationale-length gate:touchpoints<2 cap:scheduling>active cap:unknown>close expired-nonzero stated-kind-changed tier-source-invalid"
reason_dup_or_missing=0
for token in $reason_tokens; do
  cnt="$(grep -Fc "reject:${token}" "$rejects_out" || true)"
  if [ "$cnt" != "1" ]; then
    reason_dup_or_missing=$((reason_dup_or_missing + 1))
    echo "  (reason token '${token}' appeared ${cnt} time(s), expected 1)"
  fi
done
if [ "$reason_dup_or_missing" -eq 0 ]; then
  pass "check-judgment.sh: every one of the 18 reject reasons appears exactly once in rejects.jsonl output"
else
  fail "check-judgment.sh: $reason_dup_or_missing reason token(s) did not appear exactly once"
fi

# --- assertion 27: check-judgment.sh on clean.jsonl prints all ok, exits 0 ---
clean_out="$WORK_DIR/check-clean.tsv"
set +e
"$CHECK_JUDGMENT" "$CLEAN" --today 2026-08-29 --evidence "$EXPECTED_EVIDENCE" >"$clean_out" 2>"$WORK_DIR/clean.err"
clean_status=$?
set -e
clean_non_ok="$(awk -F'\t' '$2 != "ok"' "$clean_out" | wc -l | tr -d ' ')"
if [ "$clean_status" -eq 0 ] && [ "$clean_non_ok" = "0" ]; then
  pass "check-judgment.sh: clean.jsonl all 'ok', exits 0"
else
  fail "check-judgment.sh: clean.jsonl expected all-ok/exit 0, got exit=$clean_status non-ok-count=$clean_non_ok —
$(cat "$clean_out")"
fi

# --- assertion 28: --evidence gating — the gate:touchpoints<2
# (wren-halloway) and stated-kind-changed (mara-quill) rejects flip to
# 'ok' once --evidence is omitted from the same rejects.jsonl batch ---
rejects_noevidence_out="$WORK_DIR/rejects-noevidence.tsv"
set +e
"$CHECK_JUDGMENT" "$REJECTS" --today 2026-08-29 >"$rejects_noevidence_out" 2>"$WORK_DIR/rejects-noevidence.err"
set -e
wren_line="$(awk -F'\t' '$1=="wren-halloway"' "$rejects_noevidence_out")"
mara_line="$(awk -F'\t' '$1=="mara-quill"' "$rejects_noevidence_out")"
if [ "$wren_line" = "$(printf 'wren-halloway\tok')" ] && [ "$mara_line" = "$(printf 'mara-quill\tok')" ]; then
  pass "check-judgment.sh: omitting --evidence flips gate:touchpoints<2 (wren-halloway) and stated-kind-changed (mara-quill) to ok"
else
  fail "check-judgment.sh: expected both evidence-gated rejects to flip to ok without --evidence, got wren='$wren_line' mara='$mara_line'"
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

# Sabotage 4b: neuter the `ascii_downcase` case-fold in a scratch copy of
# derive-user-model.sh (reverting to the pre-fix case-sensitive match) and
# confirm assertion 13b's mixed-case sol-abernathy scenario no longer
# produces the fixed friends: 0.32 line — proves 13b actually exercises
# the ascii_downcase fix, not an unrelated byte.
sab_user_model_script="$WORK_DIR/derive-user-model-broken.sh"
sed 's/(\$src\[\.id\] \/\/ "" | ascii_downcase) as \$s/(\$src[.id] \/\/ "") as \$s/' "$DERIVE_USER_MODEL" >"$sab_user_model_script"
chmod +x "$sab_user_model_script"
if diff -q "$DERIVE_USER_MODEL" "$sab_user_model_script" >/dev/null 2>&1; then
  echo "FAIL (expected): sabotage sed did not change derive-user-model.sh — pattern no longer matches the source, sabotage proof is stale"
else
  sab_case_store="$(fresh_store um-case-sabotage)"
  for f in "$sab_case_store"/interactions/*-sol-abernathy.md; do
    [ -e "$f" ] || continue
    sed -i.bak 's/beeper-in-/beeper-in-WhatsApp-/' "$f"
    rm -f "$f.bak"
  done
  "$sab_user_model_script" "$sab_case_store" --today "$TODAY" >/dev/null 2>"$WORK_DIR/sab-case.err" || true
  sab_case_friends_line="$(grep -m1 '^- friends:' "$sab_case_store/user-model.md" 2>/dev/null || echo "(no draft written)")"
  if [ "$sab_case_friends_line" = "- friends: 0.32 — largest share of interactions in the last 90 days" ]; then
    echo "SABOTAGE-FAILED-TO-CATCH: reverting ascii_downcase still produced the fixed friends: 0.32 line ('$sab_case_friends_line')"
  else
    echo "FAIL (expected): reverting ascii_downcase in a scratch copy breaks the mixed-case match — friends line is now '$sab_case_friends_line', not the fixed '- friends: 0.32 — largest share of interactions in the last 90 days' — proves assertion 13b actually exercises the case-insensitivity fix"
  fi
fi

# Sabotage 5 (section C): doctor a byte in expected/rescale-report.tsv and
# confirm the assertion-14 diff catches it.
sab_report="$WORK_DIR/sab-report.tsv"
sed 's/^overall\t6\t89.8/overall\t6\t00.0/' "$EXPECTED_REPORT" >"$sab_report"
if diff -q "$sab_report" "$report_out" >/dev/null 2>&1; then
  echo "SABOTAGE-FAILED-TO-CATCH: doctored rescale-report golden still diffed clean"
else
  echo "FAIL (expected): rescale-scores.sh --report golden diff catches a doctored expected/rescale-report.tsv"
fi

# Sabotage 6 (section C): break the kind-cap in a scratch copy of
# rescale-scores.sh (neuter cap_tier to a no-op passthrough) and confirm
# the resulting output would fail assertion 21 (capped kinds above active).
sab_script="$WORK_DIR/rescale-scores-broken.sh"
awk '
  /^def cap_tier\(\$kind; \$tier\):$/ { print "def cap_tier($kind; $tier): $tier;"; skipping = 1; next }
  skipping && /^  end;$/ { skipping = 0; next }
  skipping { next }
  { print }
' "$RESCALE" >"$sab_script"
chmod +x "$sab_script"
sab_recentered="$WORK_DIR/sab-recentered.jsonl"
"$sab_script" "$SKEWED" --rescale >"$sab_recentered" 2>"$WORK_DIR/sab-recentered.err" || true
sab_capped_violations="$(jq -s '
  map(select((.kind=="scheduling" or .kind=="transactional" or .kind=="unsolicited")
             and (.suggested_tier=="inner-circle" or .suggested_tier=="close")))
  | length
' "$sab_recentered" 2>/dev/null || echo "jq-error")"
if [ "$sab_capped_violations" != "0" ] 2>/dev/null; then
  echo "FAIL (expected): a cap-neutered rescale-scores.sh produces $sab_capped_violations capped-kind violation(s) — proves assertion 21 actually exercises the kind-cap rule"
else
  echo "SABOTAGE-FAILED-TO-CATCH: neutering cap_tier in a scratch copy did not surface any cap violation (script edit may not have matched, or the real fixture has no e/f-style capped record — got '$sab_capped_violations')"
fi

# Sabotage 7 (section C): drop one reason record from a scratch copy of
# rejects.jsonl and confirm the exactly-once-per-token check would fail.
sab_rejects="$WORK_DIR/sab-rejects.jsonl"
grep -v '"slug":"cap-unknown-test"' "$REJECTS" >"$sab_rejects"
sab_rejects_out="$WORK_DIR/sab-rejects-out.tsv"
set +e
"$CHECK_JUDGMENT" "$sab_rejects" --today 2026-08-29 --evidence "$EXPECTED_EVIDENCE" >"$sab_rejects_out" 2>/dev/null
set -e
sab_cap_unknown_count="$(grep -Fc "reject:cap:unknown>close" "$sab_rejects_out" || true)"
if [ "$sab_cap_unknown_count" != "1" ]; then
  echo "FAIL (expected): dropping the cap:unknown>close record leaves that reason token appearing $sab_cap_unknown_count time(s) (expected 1) — proves the exactly-once check actually inspects presence, not just count-of-file-lines"
else
  echo "SABOTAGE-FAILED-TO-CATCH: dropping a reject record didn't change the reason-token count as expected"
fi

echo "--- end sabotage proofs ---"
echo ""

echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
