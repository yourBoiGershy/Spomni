#!/usr/bin/env bash
# packages/ingestion/tests/test-reindex-freshness.sh
#
# Regression-locks plan 38 D2: every script that writes people/ or
# interactions/ ends by calling packages/core/scripts/reindex.sh, so
# index.json AND stats.json are both fresh at return — never just
# index.json, never left stale for a reader to rebuild.
#
# Wired into run-structured-tests.sh (invoked near the end, its
# PASS/FAIL counts folded into the parent SUMMARY) as well as runnable
# standalone. Same style as its sibling suites: pass()/fail(), a SUMMARY
# line, non-zero exit on any failure. bash 3.2 portable (no associative
# arrays, no mapfile).
#
# Case A — packages/core/scripts/person-set-tier.sh (a core writer with
#   no ingestion dependency): a stated-by-user tier write on a copy of
#   packages/core/fixtures/store must leave index.json and stats.json
#   both newer than the edited person file, and stats.json's
#   .generated_at must have advanced past its pre-write value.
#
# Case B — packages/ingestion/scripts/file-structured.sh: reuses the
#   "01-two-known" fixture case from run-structured-tests.sh (a cheap,
#   already-set-up invocation) and asserts the same freshness property.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PERSON_SET_TIER="$REPO_ROOT/packages/core/scripts/person-set-tier.sh"
REINDEX="$REPO_ROOT/packages/core/scripts/reindex.sh"
FILE_STRUCTURED="$REPO_ROOT/packages/ingestion/scripts/file-structured.sh"
CORE_FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"
STRUCTURED_FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/structured"

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

WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# mtime_epoch <file> — portable (BSD/GNU) mtime as an epoch integer.
mtime_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

# =============================================================================
# Case A — person-set-tier.sh reindexes on a successful write.
# =============================================================================

if [ ! -x "$PERSON_SET_TIER" ]; then
  fail "case A: $PERSON_SET_TIER missing or not executable"
elif [ ! -x "$REINDEX" ]; then
  fail "case A: $REINDEX missing or not executable (sibling unit D1 not yet present)"
elif [ ! -d "$CORE_FIXTURE_STORE" ]; then
  fail "case A: fixture store missing at $CORE_FIXTURE_STORE"
else
  a_store="$WORK_DIR/case-a-store"
  cp -R "$CORE_FIXTURE_STORE" "$a_store"

  # Baseline: build both derived files once so there is a "before" state.
  "$REINDEX" "$a_store" --quiet
  a_person_file="$a_store/people/ben-whitmore.md"
  if [ ! -f "$a_person_file" ]; then
    fail "case A: fixture person file missing: $a_person_file"
  else
    a_old_generated_at="$(sed -n 's/.*"generated_at":[[:space:]]*"\([^"]*\)".*/\1/p' "$a_store/stats.json" | head -1)"

    sleep 1   # generated_at is second-precision; force a distinguishable tick

    "$PERSON_SET_TIER" "$a_store" ben-whitmore --tier active --source stated-by-user --today 2026-08-30 >/dev/null
    a_ec=$?

    if [ "$a_ec" -eq 0 ]; then
      pass "case A: person-set-tier.sh exits 0"
    else
      fail "case A: person-set-tier.sh exited $a_ec"
    fi

    a_person_mtime="$(mtime_epoch "$a_person_file")"
    a_index_mtime="$(mtime_epoch "$a_store/index.json")"
    a_stats_mtime="$(mtime_epoch "$a_store/stats.json")"

    if [ -n "$a_index_mtime" ] && [ "$a_index_mtime" -ge "$a_person_mtime" ]; then
      pass "case A: index.json mtime >= edited person file mtime"
    else
      fail "case A: index.json ($a_index_mtime) is not >= person file mtime ($a_person_mtime)"
    fi

    if [ -n "$a_stats_mtime" ] && [ "$a_stats_mtime" -ge "$a_person_mtime" ]; then
      pass "case A: stats.json mtime >= edited person file mtime"
    else
      fail "case A: stats.json ($a_stats_mtime) is not >= person file mtime ($a_person_mtime)"
    fi

    a_new_generated_at="$(sed -n 's/.*"generated_at":[[:space:]]*"\([^"]*\)".*/\1/p' "$a_store/stats.json" | head -1)"
    if [ -n "$a_new_generated_at" ] && [ "$a_new_generated_at" != "$a_old_generated_at" ]; then
      pass "case A: stats.json .generated_at advanced ($a_old_generated_at -> $a_new_generated_at)"
    else
      fail "case A: stats.json .generated_at did not advance (old=$a_old_generated_at new=$a_new_generated_at)"
    fi
  fi
fi

# =============================================================================
# Case B — file-structured.sh reindexes on a successful (non-dry-run) run.
# =============================================================================

if [ ! -x "$FILE_STRUCTURED" ]; then
  echo "case B: $FILE_STRUCTURED not present — skipping (not a failure, per run-structured-tests.sh convention)"
elif [ ! -d "$STRUCTURED_FIXTURES/cases/01-two-known" ]; then
  fail "case B: fixture case 01-two-known missing at $STRUCTURED_FIXTURES"
else
  b_store="$WORK_DIR/case-b-store"
  b_data="$WORK_DIR/case-b-data"
  b_src="$STRUCTURED_FIXTURES/cases/01-two-known"

  mkdir -p "$b_store/people" "$b_store/inbox" "$b_store/interactions"
  [ -d "$b_src/people" ] && cp "$b_src/people/"*.md "$b_store/people/" 2>/dev/null
  [ -d "$b_src/interactions" ] && cp "$b_src/interactions/"*.md "$b_store/interactions/" 2>/dev/null
  cp "$b_src/inbox/"*.md "$b_store/inbox/" 2>/dev/null

  mkdir -p "$b_data/config"
  cp "$STRUCTURED_FIXTURES/config/onboarding-backfill.tsv" "$b_data/config/onboarding-backfill.tsv"

  "$REPO_ROOT/packages/core/scripts/build-index.sh" "$b_store" >/dev/null 2>&1

  b_target_person="$(ls "$b_store/people/"*.md 2>/dev/null | head -1)"

  sleep 1

  "$FILE_STRUCTURED" "$b_store" --data-dir "$b_data" >/dev/null 2>"$WORK_DIR/case-b-err.txt"
  b_ec=$?

  if [ "$b_ec" -eq 0 ]; then
    pass "case B: file-structured.sh exits 0"
  else
    fail "case B: file-structured.sh exited $b_ec: $(cat "$WORK_DIR/case-b-err.txt")"
  fi

  b_interaction_file="$(ls "$b_store/interactions/"*.md 2>/dev/null | head -1)"
  b_ref_mtime="$(mtime_epoch "$b_interaction_file")"
  [ -z "$b_ref_mtime" ] && b_ref_mtime="$(mtime_epoch "$b_target_person")"

  b_index_mtime="$(mtime_epoch "$b_store/index.json")"
  b_stats_mtime="$(mtime_epoch "$b_store/stats.json")"

  if [ -f "$b_store/index.json" ] && [ -n "$b_index_mtime" ] && [ "$b_index_mtime" -ge "$b_ref_mtime" ]; then
    pass "case B: index.json mtime >= filed interaction file mtime"
  else
    fail "case B: index.json missing or stale (index=$b_index_mtime ref=$b_ref_mtime)"
  fi

  if [ -f "$b_store/stats.json" ] && [ -n "$b_stats_mtime" ] && [ "$b_stats_mtime" -ge "$b_ref_mtime" ]; then
    pass "case B: stats.json mtime >= filed interaction file mtime (file-structured.sh now calls reindex.sh, not build-index.sh alone)"
  else
    fail "case B: stats.json missing or stale (stats=$b_stats_mtime ref=$b_ref_mtime) — file-structured.sh must call reindex.sh so stats.json is written too"
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
