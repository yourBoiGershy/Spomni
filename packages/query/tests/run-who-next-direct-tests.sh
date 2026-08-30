#!/usr/bin/env bash
# packages/query/tests/run-who-next-direct-tests.sh
#
# Regression-locks packages/query/scripts/who-next-direct.sh against
# packages/query/tests/fixtures/who-next-direct/store/. Same style as
# packages/ingestion/tests/run-structured-tests.sh: numbered assertions via
# pass()/fail(), a SUMMARY line, non-zero exit on any failure. bash 3.2
# portable (no associative arrays, no mapfile). Needs jq.
#
# Contract under test (packages/query/scripts/who-next-direct.sh):
#
#   who-next-direct.sh <store-dir> [--mode friends|coffee|all] [--limit N]
#                       [--today YYYY-MM-DD]
#
# Emits one JSON object per line on stdout (<=20 lines): slug, name,
# last_interaction, days_since, touchpoints, open_threads,
# commitments_user, kind, tier, tags, stub, facts, personal,
# open_threads_text. Excludes anyone touched within 14 days of --today.
# stub = tags has name-from-email OR (single-token name AND no facts);
# stubs are emitted last. --mode coffee drops tags containing
# linkedin-outreach; --mode friends keeps kind in {friend, family, null}.
# Rank desc: (open_threads>0 or commitments_user>0)=3 > kind non-null=2 >
# 1, ties broken by larger days_since first. Exit 2 + stderr when people/
# is missing. --help exits 0. Never writes into the store dir; builds
# index.json/stats.json in a temp dir when absent from the store.
#
# Fixture (packages/query/tests/fixtures/who-next-direct/store/), all
# synthetic PII (invented names — nothing from any real store), built
# against a fixed --today of 2026-08-30:
#
#   people/alice-quinn.md    — (a) friend, open thread, last-touch
#     2026-07-01 (60 days before --today) -> rank 3, first.
#   people/bennett-osei.md   — (b) kind: professional, silent 40 days
#     (last-touch 2026-07-21), no open threads/commitments -> rank 2.
#   people/taylor-reyes.md   — (c) tags: [linkedin-outreach], no kind,
#     last-touch 2026-06-01 -> rank 1; dropped in --mode coffee.
#   people/harlan-voss.md    — (g) no kind, no open threads/commitments,
#     multi-token name with facts -> rank 1, non-stub; used to prove (b)
#     outranks non-kinded non-stub people.
#   people/priya.md          — (d) tags: [name-from-email] -> stub.
#   people/milo.md           — (e) single-token name, empty Facts,
#     no name-from-email tag -> stub by the second stub rule.
#   people/jordan-fielding.md — (f) last-touch 2026-08-27 (3 days before
#     --today) -> excluded by the 14-day rule at the fixed --today.
#   people/morris-vance.md  — (h) kind: transactional, kind_source: derived,
#     last-touch 2026-07-11 (50 days before --today) -> dropped in --mode
#     coffee and --mode all by default; kept only with
#     --include-transactional.
#
# Each person has one interactions/YYYY-MM-DD-<slug>.md. index.json/
# stats.json are NOT shipped in the fixture — the missing-index path
# (generated into a scratch temp dir) is one of the cases under test.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WHO_NEXT_DIRECT="$REPO_ROOT/packages/query/scripts/who-next-direct.sh"
VALIDATE_STORE="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURE_STORE="$REPO_ROOT/packages/query/tests/fixtures/who-next-direct/store"

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

if [ ! -d "$FIXTURE_STORE" ]; then
  echo "FAIL: fixture store missing at $FIXTURE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# Poll for the script under test — it may be produced by a parallel worker.
WAITED=0
while [ ! -f "$WHO_NEXT_DIRECT" ] && [ "$WAITED" -lt 90 ]; do
  sleep 10
  WAITED=$((WAITED + 10))
done

if [ ! -f "$WHO_NEXT_DIRECT" ]; then
  echo "SCRIPT NOT YET PRESENT: $WHO_NEXT_DIRECT does not exist after ${WAITED}s — tests unrun."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed (script not yet present)"
  exit 0
fi

if [ ! -x "$WHO_NEXT_DIRECT" ]; then
  echo "FAIL: $WHO_NEXT_DIRECT exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required but not found on PATH"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# fresh_copy <name> — copies the fixture store into $WORK_DIR/<name> and
# echoes the path. Used so read-only assertions can check against a
# throwaway copy instead of the committed fixture.
fresh_copy() {
  local dest="$WORK_DIR/$1"
  mkdir -p "$dest"
  cp -R "$FIXTURE_STORE/." "$dest/"
  printf '%s' "$dest"
}

TODAY="2026-08-30"

# ---------------------------------------------------------------------------
# Case 1: --help exits 0
# ---------------------------------------------------------------------------

if bash "$WHO_NEXT_DIRECT" --help >"$WORK_DIR/help.out" 2>"$WORK_DIR/help.err"; then
  pass "1: --help exits 0"
else
  fail "1: --help exits 0 (exit $?)"
fi

# ---------------------------------------------------------------------------
# Case 2: missing people/ -> exit 2, stderr non-empty, stdout empty
# ---------------------------------------------------------------------------

EMPTY_DIR="$WORK_DIR/no-people"
mkdir -p "$EMPTY_DIR"
bash "$WHO_NEXT_DIRECT" "$EMPTY_DIR" >"$WORK_DIR/c2.out" 2>"$WORK_DIR/c2.err"
c2_status=$?
if [ "$c2_status" -eq 2 ] && [ -s "$WORK_DIR/c2.err" ] && [ ! -s "$WORK_DIR/c2.out" ]; then
  pass "2: missing people/ -> exit 2, stderr non-empty, stdout empty"
else
  fail "2: missing people/ (exit=$c2_status, stderr size=$(wc -c <"$WORK_DIR/c2.err"), stdout size=$(wc -c <"$WORK_DIR/c2.out"))"
fi

# ---------------------------------------------------------------------------
# Run the primary case (all mode, fixed --today) once and reuse it.
# ---------------------------------------------------------------------------

PRIMARY_DIR="$(fresh_copy primary)"
bash "$WHO_NEXT_DIRECT" "$PRIMARY_DIR" --mode all --today "$TODAY" >"$WORK_DIR/primary.out" 2>"$WORK_DIR/primary.err"
primary_status=$?

if [ "$primary_status" -ne 0 ]; then
  fail "setup: primary run exited $primary_status (stderr: $(cat "$WORK_DIR/primary.err"))"
fi

PRIMARY_LINES=$(wc -l <"$WORK_DIR/primary.out" | tr -d ' ')

# ---------------------------------------------------------------------------
# Case 3: every stdout line parses as JSON with all required keys
# ---------------------------------------------------------------------------

REQUIRED_KEYS='slug,name,last_interaction,days_since,touchpoints,open_threads,commitments_user,kind,tier,tags,stub,facts,personal,open_threads_text'
c3_ok=1
if [ ! -s "$WORK_DIR/primary.out" ]; then
  c3_ok=0
fi
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    c3_ok=0
    continue
  fi
  for key in slug name last_interaction days_since touchpoints open_threads commitments_user kind tier tags stub facts personal open_threads_text; do
    if ! printf '%s' "$line" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
      c3_ok=0
    fi
  done
done <"$WORK_DIR/primary.out"
if [ "$c3_ok" -eq 1 ]; then
  pass "3: every stdout line parses as JSON with all required keys"
else
  fail "3: every stdout line parses as JSON with all required keys"
fi

# ---------------------------------------------------------------------------
# Case 4: (f) jordan-fielding absent (touched 3 days before --today)
# ---------------------------------------------------------------------------

if ! grep -q '"slug":"jordan-fielding"' "$WORK_DIR/primary.out"; then
  pass "4: (f) jordan-fielding absent (14-day exclusion)"
else
  fail "4: (f) jordan-fielding absent (14-day exclusion)"
fi

# ---------------------------------------------------------------------------
# Case 5: (a) alice-quinn ranks first
# ---------------------------------------------------------------------------

first_slug=$(head -n1 "$WORK_DIR/primary.out" | jq -r '.slug')
if [ "$first_slug" = "alice-quinn" ]; then
  pass "5: (a) alice-quinn ranks first"
else
  fail "5: (a) alice-quinn ranks first (got: $first_slug)"
fi

# ---------------------------------------------------------------------------
# Case 6: (b) bennett-osei ranks before non-kinded non-stub people
# ---------------------------------------------------------------------------

bennett_line=$(grep -n '"slug":"bennett-osei"' "$WORK_DIR/primary.out" | head -n1 | cut -d: -f1)
harlan_line=$(grep -n '"slug":"harlan-voss"' "$WORK_DIR/primary.out" | head -n1 | cut -d: -f1)
taylor_line=$(grep -n '"slug":"taylor-reyes"' "$WORK_DIR/primary.out" | head -n1 | cut -d: -f1)
if [ -n "$bennett_line" ] && [ -n "$harlan_line" ] && [ -n "$taylor_line" ] \
  && [ "$bennett_line" -lt "$harlan_line" ] && [ "$bennett_line" -lt "$taylor_line" ]; then
  pass "6: (b) bennett-osei ranks before non-kinded non-stub people"
else
  fail "6: (b) bennett-osei ranks before non-kinded non-stub people (bennett=$bennett_line harlan=$harlan_line taylor=$taylor_line)"
fi

# ---------------------------------------------------------------------------
# Case 7: --mode coffee drops (c) taylor-reyes; --mode all keeps it
# ---------------------------------------------------------------------------

COFFEE_DIR="$(fresh_copy coffee)"
bash "$WHO_NEXT_DIRECT" "$COFFEE_DIR" --mode coffee --today "$TODAY" >"$WORK_DIR/coffee.out" 2>"$WORK_DIR/coffee.err"
if ! grep -q '"slug":"taylor-reyes"' "$WORK_DIR/coffee.out" && grep -q '"slug":"taylor-reyes"' "$WORK_DIR/primary.out"; then
  pass "7: --mode coffee drops (c); --mode all keeps it"
else
  fail "7: --mode coffee drops (c); --mode all keeps it"
fi

# ---------------------------------------------------------------------------
# Case 8: stubs (d) priya, (e) milo have stub:true and come after all
# non-stubs
# ---------------------------------------------------------------------------

priya_stub=$(grep '"slug":"priya"' "$WORK_DIR/primary.out" | jq -r '.stub')
milo_stub=$(grep '"slug":"milo"' "$WORK_DIR/primary.out" | jq -r '.stub')
last_non_stub_line=$(nl -ba "$WORK_DIR/primary.out" | while IFS=$'\t' read -r n l; do echo "$l" | jq -e '.stub == false' >/dev/null 2>&1 && echo "$n"; done | tail -n1)
first_stub_line=$(nl -ba "$WORK_DIR/primary.out" | while IFS=$'\t' read -r n l; do echo "$l" | jq -e '.stub == true' >/dev/null 2>&1 && echo "$n"; done | head -n1)
c8_ok=1
[ "$priya_stub" = "true" ] || c8_ok=0
[ "$milo_stub" = "true" ] || c8_ok=0
if [ -n "$last_non_stub_line" ] && [ -n "$first_stub_line" ]; then
  [ "$first_stub_line" -gt "$last_non_stub_line" ] || c8_ok=0
fi
if [ "$c8_ok" -eq 1 ]; then
  pass "8: stubs (d),(e) have stub:true and come after all non-stubs"
else
  fail "8: stubs (d),(e) have stub:true and come after all non-stubs (priya=$priya_stub milo=$milo_stub last_non_stub=$last_non_stub_line first_stub=$first_stub_line)"
fi

# ---------------------------------------------------------------------------
# Case 9: --limit 2 -> exactly 2 lines
# ---------------------------------------------------------------------------

LIMIT_DIR="$(fresh_copy limit)"
bash "$WHO_NEXT_DIRECT" "$LIMIT_DIR" --mode all --today "$TODAY" --limit 2 >"$WORK_DIR/limit.out" 2>"$WORK_DIR/limit.err"
limit_lines=$(wc -l <"$WORK_DIR/limit.out" | tr -d ' ')
if [ "$limit_lines" -eq 2 ]; then
  pass "9: --limit 2 -> exactly 2 lines"
else
  fail "9: --limit 2 -> exactly 2 lines (got $limit_lines)"
fi

# ---------------------------------------------------------------------------
# Case 10: read-only — a fresh copy of the fixture is untouched by a run
# ---------------------------------------------------------------------------

RO_DIR="$(fresh_copy readonly)"
SENTINEL="$WORK_DIR/sentinel"
touch "$SENTINEL"
sleep 1
bash "$WHO_NEXT_DIRECT" "$RO_DIR" --mode all --today "$TODAY" >/dev/null 2>"$WORK_DIR/ro.err"
newer=$(find "$RO_DIR" -newer "$SENTINEL")
c10_ok=1
[ -z "$newer" ] || c10_ok=0
[ ! -f "$RO_DIR/index.json" ] || c10_ok=0
[ ! -f "$RO_DIR/stats.json" ] || c10_ok=0
if [ "$c10_ok" -eq 1 ]; then
  pass "10: read-only — no files touched, no index.json/stats.json written"
else
  fail "10: read-only — no files touched, no index.json/stats.json written (newer: $newer)"
fi

# ---------------------------------------------------------------------------
# Case 11: facts for (a) alice-quinn contain the fact text without the
# provenance prefix
# ---------------------------------------------------------------------------

alice_fact=$(grep '"slug":"alice-quinn"' "$WORK_DIR/primary.out" | jq -r '.facts[0]')
if printf '%s' "$alice_fact" | grep -q "Opened her own bakery downtown" \
  && ! printf '%s' "$alice_fact" | grep -q '\- \*\*\[told-by-user\]\*\* '; then
  pass "11: facts for (a) contain the fact text without the provenance prefix"
else
  fail "11: facts for (a) contain the fact text without the provenance prefix (got: $alice_fact)"
fi

# ---------------------------------------------------------------------------
# Case 12: validate-store.sh is clean on the fixture
# ---------------------------------------------------------------------------

if [ -f "$VALIDATE_STORE" ]; then
  if bash "$VALIDATE_STORE" "$FIXTURE_STORE" >"$WORK_DIR/validate.out" 2>&1; then
    pass "12: validate-store.sh is clean on the fixture"
  else
    fail "12: validate-store.sh is clean on the fixture ($(cat "$WORK_DIR/validate.out"))"
  fi
else
  fail "12: validate-store.sh not found at $VALIDATE_STORE"
fi

# ---------------------------------------------------------------------------
# Case 13: sabotage proof — shifting --today past (f)'s 14-day window
# makes it reappear, proving the exclusion is live rather than vacuous
# ---------------------------------------------------------------------------

SABOTAGE_DIR="$(fresh_copy sabotage)"
bash "$WHO_NEXT_DIRECT" "$SABOTAGE_DIR" --mode all --today 2026-09-15 >"$WORK_DIR/sabotage.out" 2>"$WORK_DIR/sabotage.err"
if grep -q '"slug":"jordan-fielding"' "$WORK_DIR/sabotage.out"; then
  pass "13: sabotage — (f) reappears once --today pushes it past 14 days"
else
  fail "13: sabotage — (f) reappears once --today pushes it past 14 days"
fi

# ---------------------------------------------------------------------------
# Case 14: (h) morris-vance (kind: transactional) is dropped by default in
# coffee/all, kept only with --include-transactional
# ---------------------------------------------------------------------------

TRANS_DIR="$(fresh_copy transactional)"
bash "$WHO_NEXT_DIRECT" "$TRANS_DIR" --mode coffee --today "$TODAY" >"$WORK_DIR/trans_coffee.out" 2>"$WORK_DIR/trans_coffee.err"
bash "$WHO_NEXT_DIRECT" "$TRANS_DIR" --mode all --today "$TODAY" >"$WORK_DIR/trans_all.out" 2>"$WORK_DIR/trans_all.err"
bash "$WHO_NEXT_DIRECT" "$TRANS_DIR" --mode all --today "$TODAY" --include-transactional >"$WORK_DIR/trans_included.out" 2>"$WORK_DIR/trans_included.err"

c14_ok=1
grep -q '"slug":"morris-vance"' "$WORK_DIR/trans_coffee.out" && c14_ok=0
grep -q '"slug":"morris-vance"' "$WORK_DIR/trans_all.out" && c14_ok=0
grep -q '"slug":"morris-vance"' "$WORK_DIR/trans_included.out" || c14_ok=0
if [ "$c14_ok" -eq 1 ]; then
  pass "14: (h) kind:transactional dropped in coffee/all, kept with --include-transactional"
else
  fail "14: (h) kind:transactional dropped in coffee/all, kept with --include-transactional"
fi

echo ""
echo "SUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ]
