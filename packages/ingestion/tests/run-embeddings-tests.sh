#!/usr/bin/env bash
# packages/ingestion/tests/run-embeddings-tests.sh
#
# Byte-locks packages/ingestion/scripts/embed-people.sh,
# nearest-confirmed.sh, and cluster-people.sh against
# packages/ingestion/tests/fixtures/embeddings/, per plan 30 unit 13 and
# packages/ingestion/specs/embeddings.md. Same style as
# packages/ingestion/tests/run-seed-tests.sh: numbered assertions via
# pass()/fail(), a SUMMARY line, non-zero exit on any failure. bash 3.2
# portable (no associative arrays, no mapfile).
#
# Input store: packages/ingestion/tests/fixtures/scoring/store/ (12
# people; mara-quill and ravi-sundar are the only `kind_source:
# stated-by-user` — confirmed — entries; the rest are derived or
# unkinded). Every run below works on a `mktemp -d` copy — the committed
# fixture store is never modified.
#
# Determinism: EMBED_CMD points at fixtures/embeddings/fake-embed.sh (a
# deterministic, no-network shim — see its header for the vector
# construction), and EMBED_NOW pins `embedded_at` for the "available"
# assertions.
#
# Assertion 6/9 note (locking actual script behavior over the brief's
# working assumption): nearest-confirmed.sh's *default* (`<slug>`) mode
# never probes Ollama/EMBED_CMD availability at all — it only reads the
# already-computed embeddings.jsonl, so it degrades to "embeddings:
# unavailable" solely when the file is absent or the slug/dims/candidate
# set comes up empty, regardless of OLLAMA_URL. Only its
# `--axis-similarity` mode calls embed_text (and therefore probes). The
# "three scripts, unavailable mode" assertion below therefore exercises
# embed-people.sh, nearest-confirmed.sh --axis-similarity, and
# cluster-people.sh (all three do probe) for the "bad OLLAMA_URL, existing
# file untouched" case, and separately confirms default-mode
# nearest-confirmed.sh degrades on an absent embeddings.jsonl regardless
# of OLLAMA_URL (assertion 6).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

EMBED_PEOPLE="$REPO_ROOT/packages/ingestion/scripts/embed-people.sh"
NEAREST="$REPO_ROOT/packages/ingestion/scripts/nearest-confirmed.sh"
CLUSTER="$REPO_ROOT/packages/ingestion/scripts/cluster-people.sh"
VALIDATE_STORE="$REPO_ROOT/packages/core/scripts/validate-store.sh"
SRC_STORE="$REPO_ROOT/packages/ingestion/tests/fixtures/scoring/store"
FIXTURES_DIR="$REPO_ROOT/packages/ingestion/tests/fixtures/embeddings"
SHIM="$FIXTURES_DIR/fake-embed.sh"
EXPECTED_DIR="$FIXTURES_DIR/expected"

NOW="2026-08-29T00:00:00Z"

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
for f in "$EMBED_PEOPLE" "$NEAREST" "$CLUSTER" "$VALIDATE_STORE" "$SHIM"; do
  if [ ! -x "$f" ]; then
    echo "FAIL: $f missing or not executable"
    echo ""
    echo "SUMMARY: 0 passed, 1 failed"
    exit 1
  fi
done
if [ ! -d "$SRC_STORE" ]; then
  echo "FAIL: $SRC_STORE missing"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

fresh_store() {
  # fresh_store -> prints the path to a new mktemp -d copy of the fixture
  # store (people/interactions/wakeups/index.json/stats.json).
  d="$(mktemp -d)"
  cp -R "$SRC_STORE" "$d/store"
  printf '%s/store\n' "$d"
}

# =============================================================================
# Assertions 1-4: lifecycle on one store (fresh embed, no-op re-run, edit
# -> single refresh, delete -> single drop).
# =============================================================================
STORE_A="$(fresh_store)"

out1="$(EMBED_CMD="$SHIM" EMBED_NOW="$NOW" bash "$EMBED_PEOPLE" "$STORE_A" 2>&1)"
if [ "$out1" = "embedded: 12 refreshed, 0 unchanged, 0 dropped" ]; then
  pass "1a: first embed-people.sh run summary (12 refreshed, 0 unchanged, 0 dropped)"
else
  fail "1a: first embed-people.sh run summary — got: $out1"
fi

if diff -q "$STORE_A/index/embeddings.jsonl" "$EXPECTED_DIR/embeddings.jsonl" >/dev/null 2>&1; then
  pass "1b: embeddings.jsonl byte-matches expected/embeddings.jsonl"
else
  fail "1b: embeddings.jsonl differs from expected/embeddings.jsonl"
fi

cp "$STORE_A/index/embeddings.jsonl" "$STORE_A/index/embeddings.jsonl.after-1"

out2="$(EMBED_CMD="$SHIM" EMBED_NOW="$NOW" bash "$EMBED_PEOPLE" "$STORE_A" 2>&1)"
if [ "$out2" = "embedded: 0 refreshed, 12 unchanged, 0 dropped" ]; then
  pass "2a: second (no-op) run summary (0 refreshed, 12 unchanged, 0 dropped)"
else
  fail "2a: second (no-op) run summary — got: $out2"
fi
if diff -q "$STORE_A/index/embeddings.jsonl" "$STORE_A/index/embeddings.jsonl.after-1" >/dev/null 2>&1; then
  pass "2b: embeddings.jsonl byte-identical after no-op re-run"
else
  fail "2b: embeddings.jsonl changed on a no-op re-run"
fi

# Append a Facts bullet to hal-torrance.
printf -- '- **[told-by-user]** Sent a follow-up note about a conference next spring (2026-08-29)\n' \
  >> "$STORE_A/people/hal-torrance.md"
# awk-inserted bullet lands at file end, not under "## Facts" — fine, the
# hash only needs to change; content correctness under ## Facts is
# ingestion's job elsewhere, this file only needs a differing hash here.

out3="$(EMBED_CMD="$SHIM" EMBED_NOW="$NOW" bash "$EMBED_PEOPLE" "$STORE_A" 2>&1)"
if [ "$out3" = "embedded: 1 refreshed, 11 unchanged, 0 dropped" ]; then
  pass "3a: edit-one-person run summary (1 refreshed, 11 unchanged, 0 dropped)"
else
  fail "3a: edit-one-person run summary — got: $out3"
fi

diff_lines="$(diff "$STORE_A/index/embeddings.jsonl.after-1" "$STORE_A/index/embeddings.jsonl" | grep -c '^[<>]')"
changed_slugs="$(diff "$STORE_A/index/embeddings.jsonl.after-1" "$STORE_A/index/embeddings.jsonl" | grep '^[<>]' | sed -n 's/.*"slug":"\([a-z-]*\)".*/\1/p' | sort -u)"
if [ "$diff_lines" = "2" ] && [ "$changed_slugs" = "hal-torrance" ]; then
  pass "3b: only hal-torrance's line differs after its Facts edit"
else
  fail "3b: expected exactly hal-torrance's line to differ — diff_lines=$diff_lines changed_slugs=$changed_slugs"
fi

cp "$STORE_A/index/embeddings.jsonl" "$STORE_A/index/embeddings.jsonl.after-3"

rm -f "$STORE_A/people/dex-morrow.md" "$STORE_A/interactions/2026-07-20-dex-morrow.md" "$STORE_A/interactions/2026-08-03-dex-morrow.md"

out4="$(EMBED_CMD="$SHIM" EMBED_NOW="$NOW" bash "$EMBED_PEOPLE" "$STORE_A" 2>&1)"
if [ "$out4" = "embedded: 0 refreshed, 11 unchanged, 1 dropped" ]; then
  pass "4a: delete-one-person run summary (0 refreshed, 11 unchanged, 1 dropped)"
else
  fail "4a: delete-one-person run summary — got: $out4"
fi
if jq -e 'select(.slug == "dex-morrow")' "$STORE_A/index/embeddings.jsonl" >/dev/null 2>&1; then
  fail "4b: dex-morrow line still present in embeddings.jsonl after drop"
else
  pass "4b: dex-morrow line gone from embeddings.jsonl after drop"
fi

# =============================================================================
# Assertions 5-8, 10: fresh, untouched store — byte-locked reads.
# =============================================================================
STORE_B="$(fresh_store)"
EMBED_CMD="$SHIM" EMBED_NOW="$NOW" bash "$EMBED_PEOPLE" "$STORE_B" >/dev/null 2>&1

nearest_k3="$(bash "$NEAREST" "$STORE_B" sol-abernathy --k 3)"
if [ "$nearest_k3" = "$(cat "$EXPECTED_DIR/nearest-sol-abernathy.tsv")" ]; then
  pass "5a: nearest-confirmed.sh sol-abernathy --k 3 byte-matches expected"
else
  fail "5a: nearest-confirmed.sh sol-abernathy --k 3 mismatch — got: $nearest_k3"
fi
if printf '%s\n' "$nearest_k3" | cut -f1 | sort | diff -q - <(printf 'mara-quill\nravi-sundar\n' | sort) >/dev/null 2>&1; then
  pass "5b: --k 3 lists only the two confirmed (stated-by-user) candidates"
else
  fail "5b: --k 3 candidate set is not exactly {mara-quill, ravi-sundar}"
fi

nearest_k12="$(bash "$NEAREST" "$STORE_B" sol-abernathy --k 12)"
if printf '%s\n' "$nearest_k12" | grep -q '^pip-larkin'; then
  fail "5c: pip-larkin (derived kind) appeared in --k 12 confirmed-neighbor list"
else
  pass "5c: pip-larkin (derived kind) absent even at --k 12"
fi

# Assertion 6: default-mode nearest-confirmed.sh for a slug with no
# embeddings line. See the header note: default mode never probes
# OLLAMA_URL/EMBED_CMD — it degrades purely on the file-not-found /
# slug-not-found condition, so no EMBED_CMD/OLLAMA_URL setup is needed
# here.
out6="$(bash "$NEAREST" "$STORE_B" nobody-embedded-slug --k 3 2>&1)"
rc6=$?
if [ "$out6" = "embeddings: unavailable" ] && [ "$rc6" -eq 0 ]; then
  pass "6: nearest-confirmed.sh for a slug with no embeddings line -> 'embeddings: unavailable', exit 0"
else
  fail "6: got '$out6' (exit $rc6), expected 'embeddings: unavailable' exit 0"
fi

cluster_080="$(EMBED_CMD="$SHIM" bash "$CLUSTER" "$STORE_B" --threshold 0.80)"
if [ "$cluster_080" = "$(cat "$EXPECTED_DIR/clusters-0.80.tsv")" ]; then
  pass "7a: cluster-people.sh --threshold 0.80 byte-matches expected"
else
  fail "7a: cluster-people.sh --threshold 0.80 mismatch"
fi

cluster_000="$(EMBED_CMD="$SHIM" bash "$CLUSTER" "$STORE_B" --threshold 0.0)"
n_clusters_000="$(printf '%s\n' "$cluster_000" | cut -f1 | sort -u | wc -l | tr -d ' ')"
n_yes_000="$(printf '%s\n' "$cluster_000" | awk -F'\t' '$3 == "yes"' | wc -l | tr -d ' ')"
if [ "$n_clusters_000" = "1" ] && [ "$n_yes_000" = "1" ]; then
  pass "7b: --threshold 0.0 -> exactly one cluster with one exemplar"
else
  fail "7b: --threshold 0.0 -> n_clusters=$n_clusters_000 n_yes=$n_yes_000 (expected 1/1)"
fi

cluster_999="$(EMBED_CMD="$SHIM" bash "$CLUSTER" "$STORE_B" --threshold 0.999)"
n_clusters_999="$(printf '%s\n' "$cluster_999" | cut -f1 | sort -u | wc -l | tr -d ' ')"
if [ "$n_clusters_999" = "12" ]; then
  pass "7c: --threshold 0.999 -> 12 clusters (every person distinct)"
else
  fail "7c: --threshold 0.999 -> $n_clusters_999 clusters (expected 12)"
fi

axis_out="$(EMBED_CMD="$SHIM" bash "$NEAREST" --axis-similarity "$STORE_B" --today 2026-08-29)"
if [ "$axis_out" = "$(cat "$EXPECTED_DIR/axis-similarity.json")" ]; then
  pass "8a: --axis-similarity byte-matches expected/axis-similarity.json"
else
  fail "8a: --axis-similarity mismatch — got: $axis_out"
fi
axis_keys="$(printf '%s' "$axis_out" | jq -r 'keys | sort | join(",")' 2>/dev/null)"
if [ "$axis_keys" = "business,community,family,friends,model,transactional" ]; then
  pass "8b: --axis-similarity has the five axis keys + model"
else
  fail "8b: --axis-similarity keys = '$axis_keys'"
fi

validate_out="$(bash "$VALIDATE_STORE" "$STORE_B" 2>&1)"
validate_rc=$?
if [ "$validate_rc" -eq 0 ] && printf '%s' "$validate_out" | grep -q '^store clean:'; then
  pass "10: validate-store.sh on the embedded store is clean"
else
  fail "10: validate-store.sh not clean — rc=$validate_rc out=$validate_out"
fi

# =============================================================================
# Assertion 9: unavailable mode (unset EMBED_CMD; unreachable OLLAMA_URL).
# =============================================================================
STORE_C_ABSENT="$(fresh_store)"

out9_absent_embed="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$EMBED_PEOPLE" "$STORE_C_ABSENT") 2>&1)"
if [ "$out9_absent_embed" = "embeddings: unavailable" ] && [ ! -e "$STORE_C_ABSENT/index/embeddings.jsonl" ]; then
  pass "9a: embed-people.sh unavailable, absent-file case -> 'embeddings: unavailable', no file created"
else
  fail "9a: embed-people.sh absent-file unavailable case failed — out='$out9_absent_embed' file-exists=$([ -e "$STORE_C_ABSENT/index/embeddings.jsonl" ] && echo yes || echo no)"
fi

out9_absent_cluster="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$CLUSTER" "$STORE_C_ABSENT") 2>&1)"
if [ "$out9_absent_cluster" = "embeddings: unavailable" ]; then
  pass "9b: cluster-people.sh unavailable, absent-file case -> 'embeddings: unavailable'"
else
  fail "9b: cluster-people.sh absent-file unavailable case — got: $out9_absent_cluster"
fi

out9_absent_axis="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$NEAREST" --axis-similarity "$STORE_C_ABSENT") 2>&1)"
if [ "$out9_absent_axis" = "embeddings: unavailable" ]; then
  pass "9c: nearest-confirmed.sh --axis-similarity unavailable, absent-file case -> 'embeddings: unavailable'"
else
  fail "9c: --axis-similarity absent-file unavailable case — got: $out9_absent_axis"
fi

# Existing-file case: STORE_B already has an embeddings.jsonl from the
# assertions above; confirm the three probing scripts leave it untouched
# byte-for-byte when Ollama is unreachable.
cp "$STORE_B/index/embeddings.jsonl" "$STORE_B/index/embeddings.jsonl.before-9"

out9_embed="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$EMBED_PEOPLE" "$STORE_B") 2>&1)"
if [ "$out9_embed" = "embeddings: unavailable" ] && diff -q "$STORE_B/index/embeddings.jsonl" "$STORE_B/index/embeddings.jsonl.before-9" >/dev/null 2>&1; then
  pass "9d: embed-people.sh unavailable leaves an existing embeddings.jsonl byte-identical"
else
  fail "9d: embed-people.sh unavailable case mutated or mis-reported — out='$out9_embed'"
fi

out9_cluster="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$CLUSTER" "$STORE_B") 2>&1)"
if [ "$out9_cluster" = "embeddings: unavailable" ]; then
  pass "9e: cluster-people.sh unavailable (existing file, unreachable Ollama)"
else
  fail "9e: cluster-people.sh unavailable case — got: $out9_cluster"
fi

out9_axis="$( (unset EMBED_CMD; OLLAMA_URL=http://127.0.0.1:1 bash "$NEAREST" --axis-similarity "$STORE_B") 2>&1)"
if [ "$out9_axis" = "embeddings: unavailable" ]; then
  pass "9f: nearest-confirmed.sh --axis-similarity unavailable (existing file, unreachable Ollama)"
else
  fail "9f: --axis-similarity unavailable case — got: $out9_axis"
fi

if diff -q "$STORE_B/index/embeddings.jsonl" "$STORE_B/index/embeddings.jsonl.before-9" >/dev/null 2>&1; then
  pass "9g: embeddings.jsonl still byte-identical after all three unavailable-mode calls"
else
  fail "9g: embeddings.jsonl changed across the unavailable-mode calls"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
