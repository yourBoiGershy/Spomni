#!/usr/bin/env bash
# packages/core/tests/run-merge-tests.sh
#
# Asserts packages/core/scripts/person-merge.sh against its spec (plan 36):
#
#   person-merge.sh <store-dir> <keep-slug> <drop-slug> [--data-dir <dir>] [--dry-run]
#
#   - Frontmatter union: keep wins on a scalar conflict; an empty keep scalar
#     is filled from drop; tags union; last-touch takes the max.
#   - Facts = keep's + drop's facts not already present verbatim.
#   - Open threads / Resolved: concat + dedup.
#   - `[[drop]]` -> `[[keep]]` rewritten in interactions/*.md + wakeups/**/*.md,
#     with the wakeup `people:` list deduped after rewrite.
#   - `<data-dir>/ingestion/identities.tsv` (append-only) gains a keep row for
#     each drop row.
#   - drop's person file is moved to people/.merged/<drop>.md with a
#     `merged_into:` + `merged_on:` frontmatter tombstone.
#   - `<data-dir>/ingestion/merges.log` gains a `drop\tkeep\tISO` line.
#   - build-index.sh is rerun.
#   - stdout carries a summary line:
#     `person-merge: <drop> -> <keep> facts=<n> threads=<n> links_rewritten=<n> identities=<n>`
#   - rerunning an already-merged pair exits 2 ("already merged").
#   - missing file / keep==drop exits 2.
#   - --dry-run writes nothing.
#
# This suite builds its own small synthetic store per case (example.net
# emails only) rather than depending on the shared fixtures/store/ contents.
#
# A sibling worker is landing packages/core/scripts/person-merge.sh
# concurrently with this spec. If the script is absent, every case below
# reports that precisely (script-not-landed) rather than a generic failure.
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash. Resolves all paths relative to the repo root.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

MERGE_SCRIPT="$REPO_ROOT/packages/core/scripts/person-merge.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
BUILD_INDEX="$REPO_ROOT/packages/core/scripts/build-index.sh"

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

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# script presence — must be checked before anything else so a missing
# sibling deliverable is reported precisely, not as a pile of generic FAILs.
# ---------------------------------------------------------------------------

if [ ! -f "$MERGE_SCRIPT" ]; then
  echo "SKIP: $MERGE_SCRIPT not found — person-merge.sh has not landed yet (sibling worker in flight)."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, person-merge.sh missing"
  exit 1
fi

if [ ! -x "$MERGE_SCRIPT" ]; then
  echo "FAIL: $MERGE_SCRIPT exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# fixture builder — a tiny 2-person store + identities.tsv, isolated per
# case under $TMP_ROOT/<case-name>/data/store (data-dir default is
# <store-dir>/.., so DATA_DIR = the "data" directory, STORE = data/store).
# ---------------------------------------------------------------------------

build_case() {
  # $1 = case name -> prints "$DATA_DIR $STORE_DIR" for the caller to read
  local name="$1"
  local data_dir="$TMP_ROOT/$name/data"
  local store_dir="$data_dir/store"

  mkdir -p "$store_dir/people" "$store_dir/interactions" "$store_dir/wakeups" "$data_dir/ingestion"

  cat > "$store_dir/people/keep-person.md" <<'EOF'
---
schema_version: 1.4.0
name: Keep Person
org: Acme Corp
role:
location: Springfield
tags: [college-friend]
last-touch: 2026-01-01
tier: active
---

## Facts

- **[told-by-user]** Keep's own verbatim fact (2026-01-01)

## Open threads

- Keep's own open thread (as-of 2026-01-01)

## Personal details

Keep bio text.
EOF

  cat > "$store_dir/people/drop-person.md" <<'EOF'
---
schema_version: 1.4.0
name: Drop Person
org: Widget Inc
role: Widget Engineer
location: Shelbyville
tags: [science, college-friend]
last-touch: 2026-01-10
tier: close
---

## Facts

- **[told-by-user]** Drop's own verbatim fact preserved verbatim (2026-01-10)

## Open threads

- Drop's own open thread (as-of 2026-01-10)

## Resolved

- Drop's resolved thread (resolved 2026-01-05)

## Personal details

Drop bio text.
EOF

  cat > "$store_dir/interactions/2026-01-08-drop-thread.md" <<'EOF'
---
schema_version: 1.0.0
date: 2026-01-08
people: ["[[drop-person]]"]
calendar-event: null
source-capture: 20260108T120000Z-gmail-in-test01
---

## Summary

Test interaction referencing drop.

## Commitments

- _none_
EOF

  cat > "$store_dir/wakeups/2026-01-09-drop-wakeup.md" <<'EOF'
---
schema_version: 1.0.0
id: 2026-01-09-drop-wakeup
due: 2026-01-09
people: ["[[keep-person]]", "[[drop-person]]"]
why: "test wakeup with both keep and drop linked"
status: pending
origin: user-ask
source-signal: null
---

## Context

Test wakeup body mentioning [[drop-person]] as well as [[keep-person]].
EOF

  cat > "$data_dir/ingestion/identities.tsv" <<'EOF'
keep-person	keep@example.net	cap-keep-1
drop-person	drop@example.net	cap-drop-1
EOF

  printf '%s %s' "$data_dir" "$store_dir"
}

# ===========================================================================
# Case A: dry-run leaves every file byte-identical
# ===========================================================================

echo ""
echo "--- dry-run writes nothing ---"

read -r DRY_DATA DRY_STORE <<EOF
$(build_case "case-dry-run")
EOF

DRY_BACKUP="$TMP_ROOT/case-dry-run-backup"
cp -R "$DRY_DATA" "$DRY_BACKUP"

dry_output="$("$MERGE_SCRIPT" "$DRY_STORE" keep-person drop-person --dry-run 2>&1)"
dry_status=$?

if [ "$dry_status" -eq 0 ]; then
  pass "--dry-run exits 0"
else
  fail "--dry-run exited $dry_status (expected 0): $dry_output"
fi

dry_diff="$(diff -r "$DRY_BACKUP" "$DRY_DATA" 2>&1)"
if [ -z "$dry_diff" ]; then
  pass "--dry-run leaves every file byte-identical (no writes)"
else
  fail "--dry-run wrote something to disk"
  echo "$dry_diff"
fi

# ===========================================================================
# Case B: keep == drop exits 2
# ===========================================================================

echo ""
echo "--- keep == drop refusal ---"

read -r SAME_DATA SAME_STORE <<EOF
$(build_case "case-same-slug")
EOF

same_output="$("$MERGE_SCRIPT" "$SAME_STORE" keep-person keep-person 2>&1)"
same_status=$?
if [ "$same_status" -eq 2 ]; then
  pass "keep-slug == drop-slug exits 2"
else
  fail "keep-slug == drop-slug exited $same_status (expected 2): $same_output"
fi

# ===========================================================================
# Case C: missing file exits 2
# ===========================================================================

echo ""
echo "--- missing person file refusal ---"

read -r MISSING_DATA MISSING_STORE <<EOF
$(build_case "case-missing-file")
EOF

missing_output="$("$MERGE_SCRIPT" "$MISSING_STORE" keep-person ghost-person 2>&1)"
missing_status=$?
if [ "$missing_status" -eq 2 ]; then
  pass "missing drop-slug file exits 2"
else
  fail "missing drop-slug file exited $missing_status (expected 2): $missing_output"
fi

# ===========================================================================
# Case D: the real merge — every content assertion, then rerun -> exit 2
# ===========================================================================

echo ""
echo "--- real merge: content assertions ---"

read -r REAL_DATA REAL_STORE <<EOF
$(build_case "case-real-merge")
EOF

KEEP_FILE="$REAL_STORE/people/keep-person.md"
DROP_FILE="$REAL_STORE/people/drop-person.md"
TOMBSTONE="$REAL_STORE/people/.merged/drop-person.md"
IDENTITIES="$REAL_DATA/ingestion/identities.tsv"
MERGES_LOG="$REAL_DATA/ingestion/merges.log"
INTERACTION_FILE="$REAL_STORE/interactions/2026-01-08-drop-thread.md"
WAKEUP_FILE="$REAL_STORE/wakeups/2026-01-09-drop-wakeup.md"

merge_output="$("$MERGE_SCRIPT" "$REAL_STORE" keep-person drop-person 2>&1)"
merge_status=$?

if [ "$merge_status" -eq 0 ]; then
  pass "real merge exits 0"
else
  fail "real merge exited $merge_status (expected 0): $merge_output"
fi

# --- summary line ---
if printf '%s' "$merge_output" | grep -qE '^person-merge: drop-person -> keep-person facts=[0-9]+ threads=[0-9]+ links_rewritten=[0-9]+ identities=[0-9]+$'; then
  pass "summary line matches 'person-merge: drop-person -> keep-person facts=<n> threads=<n> links_rewritten=<n> identities=<n>'"
else
  fail "summary line missing or malformed, got: $merge_output"
fi

# --- link rewrite + people-list dedup ---
if [ -f "$INTERACTION_FILE" ] && grep -qF '"[[keep-person]]"' "$INTERACTION_FILE" && ! grep -qF 'drop-person' "$INTERACTION_FILE"; then
  pass "interaction people: list rewritten [[drop-person]] -> [[keep-person]]"
else
  fail "interaction file was not rewritten as expected"
  [ -f "$INTERACTION_FILE" ] && cat "$INTERACTION_FILE"
fi

if [ -f "$WAKEUP_FILE" ]; then
  wakeup_people_line="$(grep '^people:' "$WAKEUP_FILE")"
  if printf '%s' "$wakeup_people_line" | grep -qF '"[[keep-person]]"' \
    && ! printf '%s' "$wakeup_people_line" | grep -qF 'drop-person' \
    && [ "$(printf '%s' "$wakeup_people_line" | grep -oF '[[keep-person]]' | wc -l | tr -d ' ')" = "1" ]; then
    pass "wakeup people: list rewritten and deduped to a single [[keep-person]] entry"
  else
    fail "wakeup people: list not correctly rewritten/deduped, got: $wakeup_people_line"
  fi

  if ! grep -qF 'drop-person' "$WAKEUP_FILE"; then
    pass "wakeup body [[drop-person]] reference rewritten to [[keep-person]] (no residual drop-person anywhere in file)"
  else
    fail "wakeup file still contains a drop-person reference after merge"
    cat "$WAKEUP_FILE"
  fi
else
  fail "wakeup file missing after merge: $WAKEUP_FILE"
fi

# --- told-by-user fact from drop preserved verbatim in keep ---
if [ -f "$KEEP_FILE" ] && grep -qF "Drop's own verbatim fact preserved verbatim (2026-01-10)" "$KEEP_FILE" \
  && grep -qF "Keep's own verbatim fact (2026-01-01)" "$KEEP_FILE"; then
  pass "keep's Facts contains both keep's own fact and drop's told-by-user fact, verbatim"
else
  fail "merged keep file does not contain both expected Facts bullets verbatim"
  [ -f "$KEEP_FILE" ] && cat "$KEEP_FILE"
fi

# --- open threads / resolved concat + dedup ---
if grep -qF "Keep's own open thread (as-of 2026-01-01)" "$KEEP_FILE" \
  && grep -qF "Drop's own open thread (as-of 2026-01-10)" "$KEEP_FILE"; then
  pass "Open threads carries both keep's and drop's bullets"
else
  fail "Open threads did not concat keep's and drop's bullets as expected"
fi

if grep -qF "Drop's resolved thread (resolved 2026-01-05)" "$KEEP_FILE"; then
  pass "Resolved carries drop's bullet (keep had no Resolved section of its own)"
else
  fail "Resolved section missing drop's bullet"
fi

# --- keep's scalar wins on conflict; empty scalar filled from drop; tags union ---
if grep -qxF "org: Acme Corp" "$KEEP_FILE"; then
  pass "keep's org scalar wins over drop's on conflict"
else
  fail "keep's org scalar did not win (expected 'org: Acme Corp')"
fi

if grep -qxF "role: Widget Engineer" "$KEEP_FILE"; then
  pass "keep's empty role scalar filled from drop's value"
else
  fail "keep's empty role was not filled from drop (expected 'role: Widget Engineer')"
fi

tags_line="$(grep '^tags:' "$KEEP_FILE")"
if printf '%s' "$tags_line" | grep -qF 'college-friend' && printf '%s' "$tags_line" | grep -qF 'science'; then
  pass "tags union contains both college-friend and science"
else
  fail "tags line does not contain the union of both people's tags, got: $tags_line"
fi

# --- last-touch max ---
if grep -qxF "last-touch: 2026-01-10" "$KEEP_FILE"; then
  pass "last-touch takes the max of keep's and drop's dates (2026-01-10)"
else
  fail "last-touch was not the max of the two dates"
  grep '^last-touch:' "$KEEP_FILE"
fi

# --- identity union: row count +1, original rows intact ---
if [ -f "$IDENTITIES" ]; then
  id_row_count="$(wc -l < "$IDENTITIES" | tr -d ' ')"
  if [ "$id_row_count" = "3" ]; then
    pass "identities.tsv row count is original(2) + 1 = 3"
  else
    fail "identities.tsv row count is $id_row_count (expected 3)"
  fi
  if grep -qF "$(printf 'keep-person\tkeep@example.net\tcap-keep-1')" "$IDENTITIES" \
    && grep -qF "$(printf 'drop-person\tdrop@example.net\tcap-drop-1')" "$IDENTITIES"; then
    pass "identities.tsv original rows are intact (append-only)"
  else
    fail "identities.tsv original rows were altered"
    cat "$IDENTITIES"
  fi
  if grep -qF "$(printf 'keep-person\tdrop@example.net\tcap-drop-1')" "$IDENTITIES"; then
    pass "identities.tsv gained a keep row for drop's identity row"
  else
    fail "identities.tsv is missing the new keep-person row for drop's email"
    cat "$IDENTITIES"
  fi
else
  fail "identities.tsv missing after merge: $IDENTITIES"
fi

# --- tombstone exists with merged_into / merged_on ---
if [ -f "$TOMBSTONE" ] && [ ! -f "$DROP_FILE" ]; then
  pass "drop's person file moved to people/.merged/drop-person.md and no longer at people/drop-person.md"
else
  fail "tombstone missing at $TOMBSTONE, or original drop file still present at $DROP_FILE"
fi

if [ -f "$TOMBSTONE" ] && grep -qxF "merged_into: keep-person" "$TOMBSTONE" \
  && grep -qE '^merged_on: [0-9]{4}-[0-9]{2}-[0-9]{2}' "$TOMBSTONE"; then
  pass "tombstone frontmatter has merged_into: keep-person and a merged_on date"
else
  fail "tombstone frontmatter missing expected merged_into/merged_on fields"
  [ -f "$TOMBSTONE" ] && cat "$TOMBSTONE"
fi

# --- merges.log line ---
if [ -f "$MERGES_LOG" ] && grep -qE '^drop-person	keep-person	.+$' "$MERGES_LOG"; then
  pass "merges.log gained a 'drop-person<TAB>keep-person<TAB>ISO' line"
else
  fail "merges.log missing expected drop-person/keep-person line"
  [ -f "$MERGES_LOG" ] && cat "$MERGES_LOG"
fi

# --- build-index.sh rerun ---
INDEX_FILE="$REAL_STORE/index.json"
if [ -x "$BUILD_INDEX" ] && command -v jq >/dev/null 2>&1; then
  if [ -f "$INDEX_FILE" ]; then
    has_keep=$(jq -e 'has("keep-person")' "$INDEX_FILE" 2>/dev/null)
    has_drop=$(jq -e 'has("drop-person")' "$INDEX_FILE" 2>/dev/null)
    if [ "$has_keep" = "true" ] && [ "$has_drop" != "true" ]; then
      pass "build-index.sh was rerun: index.json has keep-person and not drop-person"
    else
      fail "index.json does not reflect the merge (has_keep=$has_keep has_drop=$has_drop)"
    fi
  else
    fail "build-index.sh does not appear to have been rerun: $INDEX_FILE missing"
  fi
else
  fail "cannot check build-index.sh rerun: build-index.sh or jq unavailable"
fi

# --- validate-store.sh clean after merge (people/.merged/ skip) ---
if [ -x "$VALIDATOR" ]; then
  validate_output="$("$VALIDATOR" "$REAL_STORE" 2>&1)"
  validate_status=$?
  if [ "$validate_status" -eq 0 ]; then
    pass "validate-store.sh is clean against the post-merge store (people/.merged/ skipped)"
  else
    fail "validate-store.sh exited $validate_status (expected 0) against the post-merge store"
    echo "$validate_output"
  fi
else
  fail "cannot check validate-store.sh: $VALIDATOR not found or not executable"
fi

# --- rerun -> exit 2 ("already merged") ---
rerun_output="$("$MERGE_SCRIPT" "$REAL_STORE" keep-person drop-person 2>&1)"
rerun_status=$?
if [ "$rerun_status" -eq 2 ]; then
  pass "rerunning an already-merged pair exits 2"
else
  fail "rerunning an already-merged pair exited $rerun_status (expected 2): $rerun_output"
fi
if printf '%s' "$rerun_output" | grep -qi "already merged"; then
  pass "rerun output mentions 'already merged'"
else
  fail "rerun output did not mention 'already merged', got: $rerun_output"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
