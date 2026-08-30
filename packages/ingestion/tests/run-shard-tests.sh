#!/usr/bin/env bash
# packages/ingestion/tests/run-shard-tests.sh
#
# Regression-locks packages/ingestion/scripts/shard-filing-batch.sh (plan 27
# U6) against packages/ingestion/tests/fixtures/filing-bench/ (plan 27 U5),
# per plan 27 unit U7. Same style as run-triage-tests.sh: numbered
# assertions via pass()/fail(), a SUMMARY line, non-zero exit on any
# failure. bash 3.2 portable (no associative arrays, no mapfile).
#
# Fixture corpus: packages/ingestion/tests/fixtures/filing-bench/ — 24
# synthetic capture-event 1.2.0 files (bench-01..bench-24) plus the golden
# expected-shards.tsv id->component partition (see that directory's
# README.md for the corpus shape: 17 person-disjoint components, one
# ambiguity-merge triple (bench-08/09/10), two shared-new-person-hint pairs
# (bench-06/07, bench-11/12), one zero-hint leftover (bench-13)). No
# dedicated fixtures under tests/fixtures/shard/ were needed — the bench
# corpus expresses every case this suite needs.
#
# Every scratch store built below is a *fresh* store: empty people/, no
# index.json — so every hint in the bench corpus resolves as a "new"
# person (never an existing-slug match), matching the corpus's own design
# and the script author's reported baseline (eligible=24 components=17
# shards=8 leftover=1 against empty ledgers).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SHARD="$REPO_ROOT/packages/ingestion/scripts/shard-filing-batch.sh"
FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/filing-bench"
GOLDEN="$FIXTURES/expected-shards.tsv"

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

# --- script under test + fixtures must exist ---
if [ ! -f "$SHARD" ]; then
  echo "FAIL: $SHARD missing"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

if [ ! -d "$FIXTURES" ] || [ ! -f "$GOLDEN" ]; then
  echo "FAIL: fixture corpus missing at $FIXTURES (expected-shards.tsv)"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# setup_store <dir> — a fresh scratch store: inbox/ seeded with the full
# 24-event bench corpus, empty people/, no index.json.
setup_store() {
  dir="$1"
  mkdir -p "$dir/inbox" "$dir/people"
  cp "$FIXTURES"/bench-*.md "$dir/inbox/"
}

# summary_field <summary-line> <field-name> — extracts an integer value
# from a "shard: eligible=<n> components=<c> shards=<s> leftover=<z>" line.
summary_field() {
  printf '%s\n' "$1" | sed -n "s/.*${2}=\\([0-9][0-9]*\\).*/\\1/p"
}

SUMMARY_RE='^shard: eligible=[0-9]+ components=[0-9]+ shards=[0-9]+ leftover=[0-9]+$'

# assert_summary_matches <summary-line> <expected-line> <label>
assert_summary_matches() {
  if [ "$1" = "$2" ]; then
    pass "$3: summary line matches exactly ('$2')"
  else
    fail "$3: summary line mismatch — expected '$2', got '$1'"
  fi
}

# produced_partition <out-dir> — prints "<id>\t<label>" for every id found
# across <out-dir>/shard-*.ids (label = the shard's basename minus .ids)
# and <out-dir>/leftover.ids (label = "leftover").
produced_partition() {
  out="$1"
  for f in "$out"/shard-*.ids; do
    [ -e "$f" ] || continue
    lbl="$(basename "$f" .ids)"
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      printf '%s\t%s\n' "$id" "$lbl"
    done < "$f"
  done
  if [ -f "$out/leftover.ids" ]; then
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      printf '%s\t%s\n' "$id" "leftover"
    done < "$out/leftover.ids"
  fi
}

# assert_same_partition <golden.tsv> <produced.tsv> <label> — set-partition
# check, label spelling irrelevant. Two things must hold: (1) every golden
# component's ids stay together under one produced label — a golden
# component (cN) may never be split across two shards, since that would
# mean two parallel workers touching the same person's file; (2) every id
# is covered exactly once (no id missing, none duplicated across
# artifacts). Note this is deliberately one-directional on grouping: the
# script's bin-packing (D1) is *expected* to merge several distinct golden
# components into one shard when components outnumber --max-shards — that
# is correct behavior, not a partition mismatch, so two ids from different
# golden components landing in the same produced shard is not itself a
# failure. What must never happen is one golden component's ids landing in
# two different produced shards.
assert_same_partition() {
  golden="$1"
  produced="$2"
  label="$3"
  result="$(awk -F'\t' '
    NR == FNR { g[$1] = $2; gseen[$1] = 1; next }
    { p[$1] = $2; if (id_count[$1]++) dup[$1] = 1; pseen[$1] = 1 }
    END {
      bad = 0
      for (id in gseen) if (!(id in pseen)) { print "MISSING_IN_PRODUCED:" id; bad = 1 }
      for (id in pseen) if (!(id in gseen)) { print "EXTRA_IN_PRODUCED:" id; bad = 1 }
      for (id in dup) { print "DUPLICATE_IN_PRODUCED:" id; bad = 1 }
      if (bad) { print "RESULT:MISMATCH"; exit }
      for (id in gseen) {
        gl = g[id]; pl = p[id]
        if (gl in g2p) { if (g2p[gl] != pl) { print "GOLDEN_COMPONENT_SPLIT:" gl; bad = 1 } }
        else g2p[gl] = pl
      }
      print (bad ? "RESULT:MISMATCH" : "RESULT:MATCH")
    }
  ' "$golden" "$produced")"

  if printf '%s\n' "$result" | grep -q '^RESULT:MATCH$'; then
    pass "$label: produced partition matches golden expected-shards.tsv (every golden component stays together, every id covered exactly once, label spelling ignored)"
  else
    fail "$label: partition mismatch — $(printf '%s' "$result" | tr '\n' '; ')"
  fi
}

# ids_cogrouped <partition.tsv> <id1> <id2> — true (0) if id1 and id2 share
# the same label in <partition.tsv>.
ids_cogrouped() {
  l1="$(awk -F'\t' -v id="$2" '$1 == id { print $2 }' "$1")"
  l2="$(awk -F'\t' -v id="$3" '$1 == id { print $2 }' "$1")"
  [ -n "$l1" ] && [ "$l1" = "$l2" ]
}

# =============================================================================
# Test 1 — golden partition match vs expected-shards.tsv (empty ledgers,
# default settings). Zero-hint id (bench-13) lands in leftover.ids.
# =============================================================================

t1_store="$WORK_DIR/t1-store"
t1_out="$WORK_DIR/t1-out"
setup_store "$t1_store"

t1_summary="$("$SHARD" "$t1_store" --data-dir "$WORK_DIR/t1-data" --out-dir "$t1_out")"
t1_status=$?

if [ "$t1_status" -eq 0 ]; then
  pass "test 1: shard-filing-batch.sh exits 0 against the full bench corpus"
else
  fail "test 1: exited $t1_status (expected 0)"
fi

assert_summary_matches "$t1_summary" \
  "shard: eligible=24 components=17 shards=8 leftover=1" \
  "test 1 (default settings, empty ledgers)"

t1_produced="$WORK_DIR/t1-produced.tsv"
produced_partition "$t1_out" | sort > "$t1_produced"
sort "$GOLDEN" > "$WORK_DIR/t1-golden-sorted.tsv"
assert_same_partition "$WORK_DIR/t1-golden-sorted.tsv" "$t1_produced" "test 1"

if grep -q '^bench-13	leftover$' "$t1_produced"; then
  pass "test 1: zero-hint id bench-13 is in leftover.ids"
else
  fail "test 1: bench-13 not found labeled leftover in produced partition"
fi

if grep -q '^bench-13	shard-' "$t1_produced"; then
  fail "test 1: bench-13 (zero-hint) incorrectly also appears in a shard-*.ids file"
else
  pass "test 1: bench-13 never appears in any shard-*.ids file"
fi

# =============================================================================
# Test 2 — determinism: two runs into separate out-dirs, same store/ledgers,
# diff -r clean (artifacts and summary line both byte-identical).
# =============================================================================

t2_store="$WORK_DIR/t2-store"
setup_store "$t2_store"
t2_data="$WORK_DIR/t2-data"

t2_out_a="$WORK_DIR/t2-out-a"
t2_out_b="$WORK_DIR/t2-out-b"
t2_sum_a="$("$SHARD" "$t2_store" --data-dir "$t2_data" --out-dir "$t2_out_a")"
t2_sum_b="$("$SHARD" "$t2_store" --data-dir "$t2_data" --out-dir "$t2_out_b")"

if diff -r "$t2_out_a" "$t2_out_b" >/dev/null 2>&1; then
  pass "test 2: determinism — two runs into separate out-dirs, diff -r clean"
else
  fail "test 2: determinism — diff -r found differences between the two out-dirs: $(diff -r "$t2_out_a" "$t2_out_b" | head -5)"
fi

if [ "$t2_sum_a" = "$t2_sum_b" ]; then
  pass "test 2: determinism — summary line byte-identical across both runs"
else
  fail "test 2: determinism — summary line differs: '$t2_sum_a' vs '$t2_sum_b'"
fi

# =============================================================================
# Test 3 — eligibility respects BOTH ledgers: seed one id in
# debrief-filed.log, a different id in triage-held.log; both must be
# absent from every artifact and the summary's counts must adjust.
# =============================================================================

t3_store="$WORK_DIR/t3-store"
setup_store "$t3_store"
t3_data="$WORK_DIR/t3-data"
mkdir -p "$t3_data"
echo "bench-01" >> "$t3_data/debrief-filed.log"
printf 'bench-03\tsome-rule\t2020-01-01T00:00:00Z\n' >> "$t3_data/triage-held.log"

t3_out="$WORK_DIR/t3-out"
t3_summary="$("$SHARD" "$t3_store" --data-dir "$t3_data" --out-dir "$t3_out")"

assert_summary_matches "$t3_summary" \
  "shard: eligible=22 components=16 shards=8 leftover=1" \
  "test 3 (bench-01 filed, bench-03 held)"

t3_all_ids="$WORK_DIR/t3-all-ids"
cat "$t3_out"/shard-*.ids "$t3_out"/leftover.ids > "$t3_all_ids" 2>/dev/null

if grep -qx 'bench-01' "$t3_all_ids"; then
  fail "test 3: bench-01 (seeded in debrief-filed.log) still appears in a produced artifact"
else
  pass "test 3: bench-01 (seeded in debrief-filed.log) is absent from every artifact"
fi

if grep -qx 'bench-03' "$t3_all_ids"; then
  fail "test 3: bench-03 (seeded in triage-held.log) still appears in a produced artifact"
else
  pass "test 3: bench-03 (seeded in triage-held.log) is absent from every artifact"
fi

t3_id_count="$(sort -u "$t3_all_ids" | wc -l | tr -d ' ')"
if [ "$t3_id_count" = "22" ]; then
  pass "test 3: exactly 22 ids across all produced artifacts (24 - 2 excluded)"
else
  fail "test 3: expected 22 total ids across artifacts, got $t3_id_count"
fi

# =============================================================================
# Test 4 — ambiguity-merge: bench-08 (Alex Kim <alex.kim@example.co>),
# bench-09 (Alex Kim <alex.kim@example.org>) and bench-10 (bare "Alex Kim")
# must all land in the same shard.
# =============================================================================

t4_store="$WORK_DIR/t4-store"
setup_store "$t4_store"
t4_out="$WORK_DIR/t4-out"
"$SHARD" "$t4_store" --data-dir "$WORK_DIR/t4-data" --out-dir "$t4_out" >/dev/null

t4_produced="$WORK_DIR/t4-produced.tsv"
produced_partition "$t4_out" | sort > "$t4_produced"

if ids_cogrouped "$t4_produced" bench-08 bench-09 && ids_cogrouped "$t4_produced" bench-09 bench-10; then
  pass "test 4: ambiguity-merge — bench-08/09/10 (Alex Kim triple) co-shard"
else
  fail "test 4: ambiguity-merge — bench-08/09/10 not all co-shard: $(grep -E '^bench-(08|09|10)	' "$t4_produced" | tr '\n' '; ')"
fi

if grep -qE '^bench-(08|09|10)	leftover$' "$t4_produced"; then
  fail "test 4: one of bench-08/09/10 incorrectly landed in leftover.ids instead of a shard"
else
  pass "test 4: bench-08/09/10 are all in a shard (none dropped to leftover)"
fi

# =============================================================================
# Test 5 — shared new-person hint co-shards: bench-06/07 (same
# j.rivera@example.net hint) and bench-11/12 (same morgan.lee@example.net
# hint) must each pair co-shard.
# =============================================================================

t5_store="$WORK_DIR/t5-store"
setup_store "$t5_store"
t5_out="$WORK_DIR/t5-out"
"$SHARD" "$t5_store" --data-dir "$WORK_DIR/t5-data" --out-dir "$t5_out" >/dev/null

t5_produced="$WORK_DIR/t5-produced.tsv"
produced_partition "$t5_out" | sort > "$t5_produced"

if ids_cogrouped "$t5_produced" bench-06 bench-07; then
  pass "test 5: shared-new-person-hint — bench-06/07 (j.rivera@example.net) co-shard"
else
  fail "test 5: shared-new-person-hint — bench-06/07 not co-shard: $(grep -E '^bench-(06|07)	' "$t5_produced" | tr '\n' '; ')"
fi

if ids_cogrouped "$t5_produced" bench-11 bench-12; then
  pass "test 5: shared-new-person-hint — bench-11/12 (morgan.lee@example.net) co-shard"
else
  fail "test 5: shared-new-person-hint — bench-11/12 not co-shard: $(grep -E '^bench-(11|12)	' "$t5_produced" | tr '\n' '; ')"
fi

# =============================================================================
# Test 6 — zero-hint (bench-13) goes to leftover.ids only, never in any
# shard-*.ids file (dedicated assertion, distinct from test 1's coverage,
# so a leftover-handling regression fails here even if test 1's broader
# partition check were skipped/disabled).
# =============================================================================

t6_store="$WORK_DIR/t6-store"
setup_store "$t6_store"
t6_out="$WORK_DIR/t6-out"
"$SHARD" "$t6_store" --data-dir "$WORK_DIR/t6-data" --out-dir "$t6_out" >/dev/null

if grep -qx 'bench-13' "$t6_out/leftover.ids" 2>/dev/null; then
  pass "test 6: bench-13 (zero-hint) present in leftover.ids"
else
  fail "test 6: bench-13 not found in leftover.ids"
fi

t6_in_shard=0
for f in "$t6_out"/shard-*.ids; do
  [ -e "$f" ] || continue
  if grep -qx 'bench-13' "$f"; then
    t6_in_shard=1
  fi
done
if [ "$t6_in_shard" -eq 0 ]; then
  pass "test 6: bench-13 (zero-hint) never appears in any shard-*.ids file"
else
  fail "test 6: bench-13 incorrectly appears in a shard-*.ids file"
fi

# =============================================================================
# Test 7 — clamp: --max-shards 2 produces exactly 2 shard files covering
# all non-leftover ids, deterministically; --max-shards 99 hard-clamps to
# <=12 shard files.
# =============================================================================

t7_store="$WORK_DIR/t7-store"
setup_store "$t7_store"
t7_data="$WORK_DIR/t7-data"

t7_out_a="$WORK_DIR/t7-out-a"
t7_out_b="$WORK_DIR/t7-out-b"
t7_sum_a="$("$SHARD" "$t7_store" --data-dir "$t7_data" --max-shards 2 --out-dir "$t7_out_a")"
t7_sum_b="$("$SHARD" "$t7_store" --data-dir "$t7_data" --max-shards 2 --out-dir "$t7_out_b")"

t7_shard_files="$(ls "$t7_out_a"/shard-*.ids 2>/dev/null | wc -l | tr -d ' ')"
if [ "$t7_shard_files" = "2" ]; then
  pass "test 7: --max-shards 2 produces exactly 2 shard-*.ids files"
else
  fail "test 7: --max-shards 2 produced $t7_shard_files shard-*.ids files, expected 2"
fi

t7_shard_ids="$(cat "$t7_out_a"/shard-*.ids 2>/dev/null | sort -u | wc -l | tr -d ' ')"
t7_expected_nonleftover="$(($(wc -l < "$GOLDEN" | tr -d ' ') - 1))"
if [ "$t7_shard_ids" = "$t7_expected_nonleftover" ]; then
  pass "test 7: --max-shards 2 — all $t7_expected_nonleftover non-leftover ids present across the 2 shard files"
else
  fail "test 7: --max-shards 2 — expected $t7_expected_nonleftover total ids across shard files, got $t7_shard_ids"
fi

if diff -r "$t7_out_a" "$t7_out_b" >/dev/null 2>&1 && [ "$t7_sum_a" = "$t7_sum_b" ]; then
  pass "test 7: --max-shards 2 is deterministic across two separate runs"
else
  fail "test 7: --max-shards 2 — non-deterministic output between two runs"
fi

t7_out_99="$WORK_DIR/t7-out-99"
"$SHARD" "$t7_store" --data-dir "$t7_data" --max-shards 99 --out-dir "$t7_out_99" >/dev/null
t7_shard_files_99="$(ls "$t7_out_99"/shard-*.ids 2>/dev/null | wc -l | tr -d ' ')"
if [ "$t7_shard_files_99" -le 12 ]; then
  pass "test 7: --max-shards 99 hard-clamps to $t7_shard_files_99 shard files (<=12)"
else
  fail "test 7: --max-shards 99 produced $t7_shard_files_99 shard files, expected <=12"
fi

# =============================================================================
# Test 8 — summary line exact on empty-eligible input (every id seeded as
# filed).
# =============================================================================

t8_store="$WORK_DIR/t8-store"
setup_store "$t8_store"
t8_data="$WORK_DIR/t8-data"
mkdir -p "$t8_data"
ls "$t8_store/inbox" | sed 's/\.md$//' > "$t8_data/debrief-filed.log"

t8_out="$WORK_DIR/t8-out"
t8_summary="$("$SHARD" "$t8_store" --data-dir "$t8_data" --out-dir "$t8_out")"
t8_status=$?

assert_summary_matches "$t8_summary" \
  "shard: eligible=0 components=0 shards=0 leftover=0" \
  "test 8 (all 24 ids seeded as filed)"

if [ "$t8_status" -eq 0 ]; then
  pass "test 8: exits 0 on empty-eligible input (silence-impossible: summary still printed)"
else
  fail "test 8: exited $t8_status on empty-eligible input (expected 0)"
fi

t8_shard_file_count="$(ls "$t8_out"/shard-*.ids 2>/dev/null | wc -l | tr -d ' ')"
if [ "$t8_shard_file_count" = "0" ]; then
  pass "test 8: no shard-*.ids files written when shards=0"
else
  fail "test 8: expected 0 shard-*.ids files on empty-eligible input, got $t8_shard_file_count"
fi

# =============================================================================
# Test 9 — store tree untouched (script is read-only against <store-dir>):
# checksum every file under the store before/after, outside --out-dir
# (which is never placed inside the store here).
# =============================================================================

t9_store="$WORK_DIR/t9-store"
setup_store "$t9_store"

t9_before="$WORK_DIR/t9-before.sha"
t9_after="$WORK_DIR/t9-after.sha"
find "$t9_store" -type f | sort | xargs shasum -a 256 > "$t9_before" 2>/dev/null

"$SHARD" "$t9_store" --data-dir "$WORK_DIR/t9-data" --out-dir "$WORK_DIR/t9-out" >/dev/null

find "$t9_store" -type f | sort | xargs shasum -a 256 > "$t9_after" 2>/dev/null

if diff "$t9_before" "$t9_after" >/dev/null 2>&1; then
  pass "test 9: <store-dir> tree checksums identical before/after (read-only, nothing written outside --out-dir)"
else
  fail "test 9: <store-dir> tree changed — diff: $(diff "$t9_before" "$t9_after" | head -5)"
fi

# =============================================================================
# Fix-round tests (plan 27, T-F1 + T-F2) — a dedicated small fixture store,
# packages/ingestion/tests/fixtures/shard/store-tf/, since neither case is
# expressible from the filing-bench corpus alone (T-F2 specifically needs a
# person file whose BODY prose contains a word that also appears as a bare
# chat-title hint, which the bench corpus's people-free design can't give
# us). Synthetic PII only (example.co/.org domains).
#
#   inbox/tf1-a.md            — calendar-event, hint "Alex Kim
#                                <alex.kim@example.co>"
#   inbox/tf1-b.md             — email, hint "Alex Kim <alex.kim@example.org>"
#                                (T-F1: no bare-name hint anywhere for Alex
#                                Kim — the two email-qualified hints alone
#                                must still co-shard on the shared display
#                                name.)
#   inbox/tf2-team.md          — chat-message, bare hint "Team" (T-F2
#                                negative control: must NOT resolve against
#                                people/priya-nair.md, whose Facts prose
#                                happens to contain the word "Team".)
#   inbox/tf2-name.md          — email, bare hint "Priya Nair" (T-F2
#                                positive control: hint equal to a person's
#                                `name` field DOES resolve.)
#   inbox/tf2-index-email.md   — email, hint "priya.nair@example.co" (T-F2
#                                positive control: index.json email exact
#                                match resolves.)
#   people/priya-nair.md       — name: Priya Nair; a Facts bullet containing
#                                the word "Team" in prose ("Joined the
#                                platform Team as lead").
#   index.json                 — priya-nair entry carries an "email" field
#                                matching tf2-index-email.md's hint.
# =============================================================================

STORE_TF="$REPO_ROOT/packages/ingestion/tests/fixtures/shard/store-tf"

if [ ! -d "$STORE_TF" ]; then
  fail "fix-round fixture missing at $STORE_TF"
else
  tf_out="$WORK_DIR/tf-out"
  tf_summary="$("$SHARD" "$STORE_TF" --data-dir "$WORK_DIR/tf-data" --out-dir "$tf_out")"
  tf_status=$?

  if [ "$tf_status" -eq 0 ]; then
    pass "fix-round: shard-filing-batch.sh exits 0 against the T-F1/T-F2 fixture store"
  else
    fail "fix-round: exited $tf_status against the T-F1/T-F2 fixture store"
  fi

  tf_produced="$WORK_DIR/tf-produced.tsv"
  produced_partition "$tf_out" | sort > "$tf_produced"

  # T-F1 (HIGH): two email-qualified hints for the same not-yet-a-person
  # contact, no bare-name hint anywhere, empty people/ match for either —
  # must still co-shard via the shared normalized display name.
  if ids_cogrouped "$tf_produced" tf1-a tf1-b; then
    pass "T-F1: tf1-a (Alex Kim <alex.kim@example.co>) and tf1-b (Alex Kim <alex.kim@example.org>) co-shard on the shared display name"
  else
    fail "T-F1: tf1-a/tf1-b did not co-shard: $(grep -E '^tf1-(a|b)	' "$tf_produced" | tr '\n' '; ')"
  fi

  # T-F2 positive controls: a bare-name hint equal to a person's `name`
  # field resolves, and an index.json email exact match resolves — both
  # should land in the same group (both resolve to slug:priya-nair).
  if ids_cogrouped "$tf_produced" tf2-name tf2-index-email; then
    pass "T-F2 (positive control): tf2-name (bare 'Priya Nair') and tf2-index-email (priya.nair@example.co via index.json) co-shard (both resolve to the same known person)"
  else
    fail "T-F2 (positive control): tf2-name/tf2-index-email did not co-shard: $(grep -E '^tf2-(name|index-email)	' "$tf_produced" | tr '\n' '; ')"
  fi

  # T-F2 negative control (MEDIUM, the actual fix under test): a bare-name
  # hint "Team" must NOT resolve against people/priya-nair.md merely
  # because the word "Team" appears in that file's Facts prose —
  # resolution is restricted to identity fields (name/email), never an
  # unanchored body-text substring match.
  if ids_cogrouped "$tf_produced" tf2-team tf2-name; then
    fail "T-F2: tf2-team ('Team') incorrectly co-shards with tf2-name (Priya Nair) — resolved against body-prose text instead of identity fields only"
  else
    pass "T-F2: tf2-team ('Team') does not co-shard with the Priya Nair group — not resolved via body-prose substring match"
  fi
fi

# =============================================================================
echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
