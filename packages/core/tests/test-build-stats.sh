#!/usr/bin/env bash
# packages/core/tests/test-build-stats.sh
#
# Golden test for packages/core/scripts/build-stats.sh against
# packages/core/fixtures/store/. Every expected value below was hand-computed
# from the fixture markdown files and packages/core/contracts/derived-index.md
# — NOT read off build-stats.sh's own output — per docs/DECISIONS.md's
# golden-tests-before-prompts rule.
#
# Goldens (hand-counted, cited by source file):
#   - people/ has exactly 31 person files (`ls people/*.md | wc -l`).
#   - grace-lindqvist: 11 interactions/*.md files list [[grace-lindqvist]]
#     (2025-10-03, 2025-11-14, 2025-12-19, 2026-01-16, 2026-02-13,
#     2026-03-20, 2026-04-17, 2026-05-15, 2026-06-12, 2026-07-24,
#     2026-08-26) => touchpoints=11, first_interaction=2025-10-03,
#     last_interaction=2026-08-26. people/grace-lindqvist.md's
#     `## Open threads` has 2 bullets.
#   - priyanka-deshmukh: no interactions/*.md file lists
#     [[priyanka-deshmukh]] => touchpoints=0, first/last_interaction=null,
#     median_gap_days=null, interactions=[].
#   - interactions/2026-07-20-combs-family-reunion.md: people list is
#     ["[[eleanor-combs]]", "[[walter-combs]]", "[[ravi-kapoor]]"], one
#     Commitments bullet owned by [[ravi-kapoor]]. This interaction must
#     appear under BOTH walter-combs (others=[eleanor-combs, ravi-kapoor])
#     and ravi-kapoor (others=[eleanor-combs, walter-combs]).
#   - walter-combs: interactions/2026-07-20-combs-family-reunion.md (date
#     2026-07-20) + interactions/2026-08-05-walter-combs.md (date
#     2026-08-05, one-on-one, Commitments bullet owned by `user`) =>
#     touchpoints=2, first_interaction=2026-07-20,
#     last_interaction=2026-08-05, commitments={user:1, them:0}.
#     people/walter-combs.md's `## Open threads` has 1 bullet
#     => open_threads must equal 1.
#   - ravi-kapoor: only interactions/2026-07-20-combs-family-reunion.md =>
#     touchpoints=1, commitments={user:0, them:1} (the bullet's owner
#     [[ravi-kapoor]] is his own slug).
#
# bash 3.2 portable (no associative arrays, no mapfile) + jq.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BUILD_STATS="$REPO_ROOT/packages/core/scripts/build-stats.sh"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"

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

summary_and_exit() {
  echo ""
  echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
  else
    exit 1
  fi
}

# --- build-stats.sh must exist ---
if [ ! -f "$BUILD_STATS" ]; then
  echo "SKIP: $BUILD_STATS not found — cannot run build-stats golden test yet."
  fail "build-stats.sh missing at $BUILD_STATS"
  summary_and_exit
fi

if [ ! -x "$BUILD_STATS" ]; then
  fail "$BUILD_STATS exists but is not executable"
  summary_and_exit
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  fail "fixture store missing at $FIXTURE_STORE"
  summary_and_exit
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required but not found on PATH"
  summary_and_exit
fi

# --- run against a temp copy of the fixture store; never write into the
#     committed fixture dir. ---
TMP_STORE_1="$(mktemp -d 2>/dev/null || mktemp -d -t 'build-stats-test')"
TMP_STORE_2="$(mktemp -d 2>/dev/null || mktemp -d -t 'build-stats-test')"

cleanup() {
  rm -rf "$TMP_STORE_1" "$TMP_STORE_2"
}
trap cleanup EXIT

cp -R "$FIXTURE_STORE/." "$TMP_STORE_1/"
cp -R "$FIXTURE_STORE/." "$TMP_STORE_2/"

run1_output="$("$BUILD_STATS" "$TMP_STORE_1" 2>&1)"
run1_status=$?
STATS_1="$TMP_STORE_1/stats.json"

if [ "$run1_status" -ne 0 ]; then
  fail "build-stats.sh exited $run1_status (expected 0) against the fixture store"
  echo "$run1_output"
  summary_and_exit
fi

if [ ! -f "$STATS_1" ]; then
  fail "build-stats.sh did not produce stats.json at $STATS_1"
  summary_and_exit
fi

if ! jq -e . "$STATS_1" >/dev/null 2>&1; then
  fail "stats.json at $STATS_1 is not valid JSON"
  summary_and_exit
fi

# =====================================================================
# (a) schema: schema_version, generated_at, every people/ slug present
# =====================================================================

schema_version="$(jq -r '.schema_version' "$STATS_1")"
if [ "$schema_version" = "1.0.0" ]; then
  pass "schema_version is 1.0.0"
else
  fail "schema_version is '$schema_version' (expected 1.0.0)"
fi

generated_at="$(jq -r '.generated_at // empty' "$STATS_1")"
if [ -n "$generated_at" ]; then
  pass "generated_at is present ($generated_at)"
else
  fail "generated_at is missing or empty"
fi

people_count_expected=31
people_count_fixture="$(ls "$FIXTURE_STORE"/people/*.md 2>/dev/null | wc -l | tr -d ' ')"
if [ "$people_count_fixture" -ne "$people_count_expected" ]; then
  fail "fixture drift: people/ now has $people_count_fixture files, golden assumed $people_count_expected — update this test's goldens"
fi

people_count_stats="$(jq -r '.people | length' "$STATS_1")"
if [ "$people_count_stats" -eq "$people_count_expected" ]; then
  pass "stats.json.people has $people_count_expected entries (matches people/ file count)"
else
  fail "stats.json.people has $people_count_stats entries (expected $people_count_expected)"
fi

missing_slugs=""
for f in "$FIXTURE_STORE"/people/*.md; do
  slug="$(basename "$f" .md)"
  present="$(jq -r --arg slug "$slug" '.people | has($slug)' "$STATS_1")"
  if [ "$present" != "true" ]; then
    missing_slugs="$missing_slugs $slug"
  fi
done
if [ -z "$missing_slugs" ]; then
  pass "every people/ slug appears in stats.json.people"
else
  fail "slugs missing from stats.json.people:$missing_slugs"
fi

# =====================================================================
# (b) spot goldens
# =====================================================================

# --- grace-lindqvist: 11 touchpoints, first 2025-10-03, last 2026-08-26,
#     open_threads matching her 2 `## Open threads` bullets ---
grace_touchpoints="$(jq -r '.people["grace-lindqvist"].touchpoints' "$STATS_1")"
if [ "$grace_touchpoints" = "11" ]; then
  pass "grace-lindqvist.touchpoints is 11"
else
  fail "grace-lindqvist.touchpoints is '$grace_touchpoints' (expected 11)"
fi

grace_first="$(jq -r '.people["grace-lindqvist"].first_interaction' "$STATS_1")"
if [ "$grace_first" = "2025-10-03" ]; then
  pass "grace-lindqvist.first_interaction is 2025-10-03"
else
  fail "grace-lindqvist.first_interaction is '$grace_first' (expected 2025-10-03)"
fi

grace_last="$(jq -r '.people["grace-lindqvist"].last_interaction' "$STATS_1")"
if [ "$grace_last" = "2026-08-26" ]; then
  pass "grace-lindqvist.last_interaction is 2026-08-26"
else
  fail "grace-lindqvist.last_interaction is '$grace_last' (expected 2026-08-26)"
fi

grace_open_threads_bullets="$(awk '/^## Open threads/{f=1;next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$FIXTURE_STORE/people/grace-lindqvist.md")"
grace_open_threads_stats="$(jq -r '.people["grace-lindqvist"].open_threads' "$STATS_1")"
if [ "$grace_open_threads_stats" = "$grace_open_threads_bullets" ] && [ "$grace_open_threads_bullets" = "2" ]; then
  pass "grace-lindqvist.open_threads is 2 (matches her ## Open threads bullet count)"
else
  fail "grace-lindqvist.open_threads is '$grace_open_threads_stats', hand-counted bullets = '$grace_open_threads_bullets' (expected both 2)"
fi

# --- priyanka-deshmukh: 0 touchpoints, nulls, empty interactions list ---
priyanka_touchpoints="$(jq -r '.people["priyanka-deshmukh"].touchpoints' "$STATS_1")"
if [ "$priyanka_touchpoints" = "0" ]; then
  pass "priyanka-deshmukh.touchpoints is 0"
else
  fail "priyanka-deshmukh.touchpoints is '$priyanka_touchpoints' (expected 0)"
fi

priyanka_first="$(jq -r '.people["priyanka-deshmukh"].first_interaction' "$STATS_1")"
priyanka_last="$(jq -r '.people["priyanka-deshmukh"].last_interaction' "$STATS_1")"
priyanka_gap="$(jq -r '.people["priyanka-deshmukh"].median_gap_days' "$STATS_1")"
if [ "$priyanka_first" = "null" ] && [ "$priyanka_last" = "null" ] && [ "$priyanka_gap" = "null" ]; then
  pass "priyanka-deshmukh.first_interaction / last_interaction / median_gap_days are all null"
else
  fail "priyanka-deshmukh nulls not as expected (first=$priyanka_first, last=$priyanka_last, median_gap_days=$priyanka_gap)"
fi

priyanka_interactions_len="$(jq -r '.people["priyanka-deshmukh"].interactions | length' "$STATS_1")"
if [ "$priyanka_interactions_len" = "0" ]; then
  pass "priyanka-deshmukh.interactions is an empty list"
else
  fail "priyanka-deshmukh.interactions has $priyanka_interactions_len entries (expected 0)"
fi

# --- multi-person interaction (2026-07-20-combs-family-reunion) appears
#     under both walter-combs and ravi-kapoor, with the other participant(s)
#     in `others` ---
walter_others="$(jq -c '.people["walter-combs"].interactions[] | select(.id == "2026-07-20-combs-family-reunion") | .others | sort' "$STATS_1")"
if [ "$walter_others" = '["eleanor-combs","ravi-kapoor"]' ]; then
  pass "walter-combs's 2026-07-20-combs-family-reunion.others is [eleanor-combs, ravi-kapoor]"
else
  fail "walter-combs's 2026-07-20-combs-family-reunion.others is '$walter_others' (expected [eleanor-combs, ravi-kapoor])"
fi

ravi_others="$(jq -c '.people["ravi-kapoor"].interactions[] | select(.id == "2026-07-20-combs-family-reunion") | .others | sort' "$STATS_1")"
if [ "$ravi_others" = '["eleanor-combs","walter-combs"]' ]; then
  pass "ravi-kapoor's 2026-07-20-combs-family-reunion.others is [eleanor-combs, walter-combs]"
else
  fail "ravi-kapoor's 2026-07-20-combs-family-reunion.others is '$ravi_others' (expected [eleanor-combs, walter-combs])"
fi

# --- walter-combs: open_threads matches his 1 `## Open threads` bullet ---
walter_open_threads_bullets="$(awk '/^## Open threads/{f=1;next} /^## /{f=0} f && /^- /{c++} END{print c+0}' "$FIXTURE_STORE/people/walter-combs.md")"
walter_open_threads_stats="$(jq -r '.people["walter-combs"].open_threads' "$STATS_1")"
if [ "$walter_open_threads_stats" = "$walter_open_threads_bullets" ] && [ "$walter_open_threads_bullets" = "1" ]; then
  pass "walter-combs.open_threads is 1 (matches his ## Open threads bullet count)"
else
  fail "walter-combs.open_threads is '$walter_open_threads_stats', hand-counted bullets = '$walter_open_threads_bullets' (expected both 1)"
fi

# --- walter-combs / ravi-kapoor commitments split (contract's own
#     worked example): the family-reunion bullet is owned by
#     [[ravi-kapoor]], so it counts toward ravi's `them`, not walter's. ---
walter_commitments="$(jq -c '.people["walter-combs"].commitments' "$STATS_1")"
if [ "$(jq '.people["walter-combs"].commitments.user' "$STATS_1")" = "1" ] && \
   [ "$(jq '.people["walter-combs"].commitments.them' "$STATS_1")" = "0" ]; then
  pass "walter-combs.commitments is {user:1, them:0}"
else
  fail "walter-combs.commitments is '$walter_commitments' (expected {user:1, them:0})"
fi

ravi_commitments="$(jq -c '.people["ravi-kapoor"].commitments' "$STATS_1")"
if [ "$(jq '.people["ravi-kapoor"].commitments.user' "$STATS_1")" = "0" ] && \
   [ "$(jq '.people["ravi-kapoor"].commitments.them' "$STATS_1")" = "1" ]; then
  pass "ravi-kapoor.commitments is {user:0, them:1}"
else
  fail "ravi-kapoor.commitments is '$ravi_commitments' (expected {user:0, them:1})"
fi

# =====================================================================
# (c) interactions sorted newest-first
# =====================================================================

grace_dates_desc_check="$(jq -r '.people["grace-lindqvist"].interactions | [.[].date] as $d | ($d == ($d | sort | reverse))' "$STATS_1")"
if [ "$grace_dates_desc_check" = "true" ]; then
  pass "grace-lindqvist.interactions is sorted newest-first by date"
else
  fail "grace-lindqvist.interactions is NOT sorted newest-first by date"
fi

grace_first_id_date="$(jq -r '.people["grace-lindqvist"].interactions[0].date' "$STATS_1")"
grace_last_id_date="$(jq -r '.people["grace-lindqvist"].interactions[-1].date' "$STATS_1")"
if [ "$grace_first_id_date" = "2026-08-26" ] && [ "$grace_last_id_date" = "2025-10-03" ]; then
  pass "grace-lindqvist.interactions[0] is the newest (2026-08-26) and [-1] is the oldest (2025-10-03)"
else
  fail "grace-lindqvist.interactions ordering is off (first=$grace_first_id_date, last=$grace_last_id_date)"
fi

# =====================================================================
# (d) determinism: two runs differ only in generated_at
# =====================================================================

run2_output="$("$BUILD_STATS" "$TMP_STORE_2" 2>&1)"
run2_status=$?
STATS_2="$TMP_STORE_2/stats.json"

if [ "$run2_status" -ne 0 ] || [ ! -f "$STATS_2" ]; then
  fail "second build-stats.sh run failed (status=$run2_status) or produced no stats.json — cannot check determinism"
else
  normalized_1="$(jq -S 'del(.generated_at)' "$STATS_1")"
  normalized_2="$(jq -S 'del(.generated_at)' "$STATS_2")"
  if [ "$normalized_1" = "$normalized_2" ]; then
    pass "two runs of build-stats.sh produce identical output aside from generated_at"
  else
    fail "two runs of build-stats.sh differ beyond generated_at — output is not deterministic"
  fi
fi

# --- committed fixture dir must not have gained a stats.json ---
if [ -f "$FIXTURE_STORE/stats.json" ]; then
  fail "packages/core/fixtures/store/stats.json exists — the fixture dir must stay pristine (test must run against a temp copy)"
else
  pass "committed fixture store has no stats.json (test ran against a temp copy, as required)"
fi

summary_and_exit
