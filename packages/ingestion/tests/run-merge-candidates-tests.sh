#!/usr/bin/env bash
# packages/ingestion/tests/run-merge-candidates-tests.sh
#
# Regression-locks packages/ingestion/scripts/find-merge-candidates.sh
# against packages/ingestion/tests/fixtures/merge-candidates/, per plan 36
# (store currency / dedup). Same style as run-thread-tests.sh: numbered
# assertions via pass()/fail(), a SUMMARY line, non-zero exit on any
# failure. bash 3.2 portable (no associative arrays, no mapfile). No model
# calls — find-merge-candidates.sh is a pure read-only scan.
#
# Fixtures (packages/ingestion/tests/fixtures/merge-candidates/), all
# synthetic PII (invented names, example.net-only addresses):
#
#   store/people/*.md — 11 live people + one people/.merged/ tombstone
#     (old-duplicate.md, must be ignored entirely):
#       dhruv.md / dhruv-mehta.md   — different names, same org
#         (Beacon Labs) -> slug-prefix+org (dhruv-mehta is a prefix
#         extension of dhruv). dhruv-mehta has 2 interactions, dhruv has
#         1 -> keep dhruv-mehta.
#       patrick.md / patrick-proulx.md — different names/orgs, but both
#         map to patrick@example.net in identities.tsv -> shared-identity
#         (which also happens to be a slug-prefix pair — shared-identity
#         must win over slug-prefix). patrick-proulx has 2 interactions,
#         patrick has 1 -> keep patrick-proulx.
#       rahul.md / rahul-2.md / rahul-3.md — all normalize to "Rahul
#         Iyer" (rahul-3.md spells it "Rahul Íyer", a diacritic variant)
#         -> same-name on all 3 pairs (same-name outranks the
#         rahul/rahul-2 slug-prefix that would otherwise also fire).
#         rahul-2 has 2 interactions, rahul has 1, rahul-3 has 0.
#       josh.md / joshua-tan.md — different names, same org (Fern Co),
#         NOT a slug-prefix pair ("joshua-tan" does not start with
#         "josh-") and no shared identity -> must NOT pair (same org
#         alone is never sufficient).
#       mira.md / mira-chen.md — different names, different orgs (Acme
#         Corp / Zeta LLC), slug-prefix pair, both have identities.tsv
#         rows at example.net -> slug-prefix+domain (org doesn't match,
#         domain does). mira-chen has 2 interactions, mira has 1 -> keep
#         mira-chen.
#       people/.merged/old-duplicate.md — a merge tombstone; must never
#         appear in any output row and must not affect any count.
#   store/interactions/*.md — one interaction per person named above
#     (dhruv-mehta and patrick-proulx and rahul-2 and mira-chen each get
#     2, giving them the higher [[slug]] link count of their pair).
#   data/ingestion/identities.tsv — patrick/patrick-proulx (shared
#     email), mira/mira-chen (shared domain, different local parts), and
#     one row for "ghost-user", a slug with no people/ghost-user.md file
#     at all (stale-row-ignored case).
#
# Expected output (data/ingestion/identities.tsv passed via --data-dir):
#   candidates=6
#   dhruv-mehta	dhruv	slug-prefix+org
#   mira-chen	mira	slug-prefix+domain
#   patrick-proulx	patrick	shared-identity:patrick@example.net
#   rahul	rahul-3	same-name
#   rahul-2	rahul	same-name
#   rahul-2	rahul-3	same-name

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

FIND_MERGE="$REPO_ROOT/packages/ingestion/scripts/find-merge-candidates.sh"
FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/merge-candidates"
FIXTURE_STORE="$FIXTURES/store"
FIXTURE_DATA="$FIXTURES/data"

PASS_COUNT=0
FAIL_COUNT=0
FAIL_REASONS=""

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAIL_REASONS="${FAIL_REASONS}
  - $1"
  echo "FAIL: $1"
}

if [ ! -x "$FIND_MERGE" ]; then
  echo "NOTE: $FIND_MERGE is not present/executable yet — every case below"
  echo "      that depends on it is expected to fail until it lands."
fi

if [ ! -d "$FIXTURES" ]; then
  echo "FAIL: fixtures missing at $FIXTURES"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Case 1: missing store-dir -> exit 2
# ---------------------------------------------------------------------------

c1_out="$WORK_DIR/c1-out.txt"
c1_err="$WORK_DIR/c1-err.txt"
"$FIND_MERGE" "$WORK_DIR/does-not-exist" --data-dir "$FIXTURE_DATA" \
  > "$c1_out" 2>"$c1_err"
c1_rc=$?
if [ "$c1_rc" -eq 2 ]; then
  pass "missing store-dir exits 2"
else
  fail "missing store-dir exit code: got $c1_rc, want 2 (stderr: $(cat "$c1_err" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# Case 2: main run against the fixture store (copied so we can diff -r
# the original fixture afterward and prove nothing was written).
# ---------------------------------------------------------------------------

c2_store="$WORK_DIR/c2-store"
cp -R "$FIXTURE_STORE" "$c2_store"

c2_out="$WORK_DIR/c2-out.txt"
c2_err="$WORK_DIR/c2-err.txt"
"$FIND_MERGE" "$c2_store" --data-dir "$FIXTURE_DATA" > "$c2_out" 2>"$c2_err"
c2_rc=$?

if [ "$c2_rc" -eq 0 ]; then
  pass "main run exits 0"
else
  fail "main run exit code: got $c2_rc, want 0 (stderr: $(cat "$c2_err" 2>/dev/null))"
fi

c2_first_line="$(head -1 "$c2_out" 2>/dev/null)"
if [ "$c2_first_line" = "candidates=6" ]; then
  pass "first line is candidates=6"
else
  fail "first line: got '$c2_first_line', want 'candidates=6'"
fi

c2_body="$WORK_DIR/c2-body.txt"
tail -n +2 "$c2_out" > "$c2_body" 2>/dev/null

check_row() {
  label="$1"
  row="$2"
  if grep -qxF "$row" "$c2_body" 2>/dev/null; then
    pass "row present: $label"
  else
    fail "row missing: $label (want line: '$row')"
  fi
}

check_row "dhruv/dhruv-mehta slug-prefix+org" \
  "$(printf 'dhruv-mehta\tdhruv\tslug-prefix+org')"
check_row "mira/mira-chen slug-prefix+domain" \
  "$(printf 'mira-chen\tmira\tslug-prefix+domain')"
check_row "patrick/patrick-proulx shared-identity" \
  "$(printf 'patrick-proulx\tpatrick\tshared-identity:patrick@example.net')"
check_row "rahul/rahul-3 same-name" \
  "$(printf 'rahul\trahul-3\tsame-name')"
check_row "rahul-2/rahul same-name" \
  "$(printf 'rahul-2\trahul\tsame-name')"
check_row "rahul-2/rahul-3 same-name" \
  "$(printf 'rahul-2\trahul-3\tsame-name')"

if grep -qi "josh" "$c2_body" 2>/dev/null; then
  fail "josh/joshua-tan row present (must not pair)"
else
  pass "no josh/joshua-tan row"
fi

if grep -qi "old-duplicate\|\.merged" "$c2_body" 2>/dev/null; then
  fail "people/.merged/old-duplicate.md tombstone leaked into output"
else
  pass "tombstone (people/.merged/) ignored"
fi

body_lines="$(wc -l < "$c2_body" 2>/dev/null | tr -d ' ')"
if [ "$body_lines" = "6" ]; then
  pass "body has exactly 6 rows"
else
  fail "body row count: got $body_lines, want 6"
fi

if [ -s "$c2_body" ]; then
  if sort -c "$c2_body" 2>/dev/null; then
    pass "output rows are sorted"
  else
    fail "output rows are not sorted"
  fi
else
  fail "output body is empty, cannot check sort order"
fi

# ---------------------------------------------------------------------------
# Case 3: store is byte-identical to the fixture after the run
# ---------------------------------------------------------------------------

if diff -r "$FIXTURE_STORE" "$c2_store" >"$WORK_DIR/c3-diff.txt" 2>&1; then
  pass "store byte-identical after run (diff -r clean)"
else
  fail "store mutated by a read-only run: $(cat "$WORK_DIR/c3-diff.txt")"
fi

# ---------------------------------------------------------------------------
# Case 4: default --data-dir (<store>/..) resolves identities.tsv too
# ---------------------------------------------------------------------------

c4_root="$WORK_DIR/c4-root"
mkdir -p "$c4_root"
cp -R "$FIXTURE_STORE" "$c4_root/store"
cp -R "$FIXTURE_DATA/ingestion" "$c4_root/ingestion"

c4_out="$WORK_DIR/c4-out.txt"
c4_err="$WORK_DIR/c4-err.txt"
"$FIND_MERGE" "$c4_root/store" > "$c4_out" 2>"$c4_err"
c4_rc=$?

if [ "$c4_rc" -eq 0 ]; then
  pass "default --data-dir run exits 0"
else
  fail "default --data-dir run exit code: got $c4_rc, want 0 (stderr: $(cat "$c4_err" 2>/dev/null))"
fi

c4_first_line="$(head -1 "$c4_out" 2>/dev/null)"
if [ "$c4_first_line" = "candidates=6" ]; then
  pass "default --data-dir resolves identities.tsv (candidates=6)"
else
  fail "default --data-dir first line: got '$c4_first_line', want 'candidates=6' (identities.tsv not found via <store>/.. default?)"
fi

echo
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "FAILURES:$FAIL_REASONS"
  exit 1
fi
exit 0
