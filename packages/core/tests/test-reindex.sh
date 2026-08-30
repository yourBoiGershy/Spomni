#!/usr/bin/env bash
# packages/core/tests/test-reindex.sh
#
# Golden test for packages/core/scripts/reindex.sh (plan 38 unit D1) — the
# one call every store writer makes after touching people/ or
# interactions/. Runs build-index.sh then build-stats.sh, idempotent,
# exits non-zero if either fails.
#
# bash 3.2 portable (no associative arrays, no mapfile) + jq.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REINDEX="$REPO_ROOT/packages/core/scripts/reindex.sh"
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

# Portable mtime-in-epoch-seconds: try GNU coreutils form first (`-c`) --
# BSD/macOS stat rejects `-c` with a clean "illegal option" exit failure,
# so the `||` correctly falls through to the BSD form (`-f '%m'`). The
# reverse order is NOT safe: GNU stat's `-f` flag means "filesystem status"
# (not file status) and exits 0 while printing the wrong thing, so it
# never trips the `||` fallback on Linux.
mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# --- reindex.sh must exist ---
if [ ! -f "$REINDEX" ]; then
  echo "SKIP: $REINDEX not found — cannot run reindex.sh golden test yet."
  fail "reindex.sh missing at $REINDEX"
  summary_and_exit
fi

if [ ! -x "$REINDEX" ]; then
  fail "$REINDEX exists but is not executable"
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
TMP_STORE="$(mktemp -d 2>/dev/null || mktemp -d -t 'reindex-test')"

cleanup() {
  rm -rf "$TMP_STORE"
}
trap cleanup EXIT

cp -R "$FIXTURE_STORE/." "$TMP_STORE/"
rm -f "$TMP_STORE/index.json" "$TMP_STORE/stats.json"

# =====================================================================
# (a) basic run: both artifacts produced, exit 0
# =====================================================================

run_output="$("$REINDEX" "$TMP_STORE" 2>&1)"
run_status=$?

if [ "$run_status" -eq 0 ]; then
  pass "reindex.sh exits 0 against the fixture store"
else
  fail "reindex.sh exited $run_status (expected 0): $run_output"
fi

if [ -f "$TMP_STORE/index.json" ]; then
  pass "reindex.sh produced index.json"
else
  fail "reindex.sh did not produce index.json"
fi

if [ -f "$TMP_STORE/stats.json" ]; then
  pass "reindex.sh produced stats.json"
else
  fail "reindex.sh did not produce stats.json"
fi

if [ -f "$TMP_STORE/stats.json" ] && jq -e '.generated_at' "$TMP_STORE/stats.json" >/dev/null 2>&1; then
  pass "stats.json.generated_at parses as valid JSON"
else
  fail "stats.json.generated_at missing or does not parse"
fi

# --- non-quiet mode prints the one summary line ---
if printf '%s' "$run_output" | grep -qF "reindexed ${TMP_STORE}: index.json + stats.json"; then
  pass "non-quiet reindex.sh prints the one summary line"
else
  fail "non-quiet reindex.sh did not print the expected summary line: $run_output"
fi

# =====================================================================
# (b) freshness: both files' mtimes >= newest mtime under people/ +
#     interactions/
# =====================================================================

newest_source_mtime=""
source_files="$(find "$TMP_STORE/people" "$TMP_STORE/interactions" -type f -name '*.md' 2>/dev/null)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  m="$(mtime "$f")"
  [ -z "$m" ] && continue
  if [ -z "$newest_source_mtime" ] || [ "$m" -gt "$newest_source_mtime" ]; then
    newest_source_mtime="$m"
  fi
done <<< "$source_files"

index_mtime="$(mtime "$TMP_STORE/index.json")"
stats_mtime="$(mtime "$TMP_STORE/stats.json")"

if [ -n "$newest_source_mtime" ] && [ -n "$index_mtime" ] && [ "$index_mtime" -ge "$newest_source_mtime" ]; then
  pass "index.json mtime >= newest mtime under people/+interactions/"
else
  fail "index.json mtime ($index_mtime) is older than newest source mtime ($newest_source_mtime)"
fi

if [ -n "$newest_source_mtime" ] && [ -n "$stats_mtime" ] && [ "$stats_mtime" -ge "$newest_source_mtime" ]; then
  pass "stats.json mtime >= newest mtime under people/+interactions/"
else
  fail "stats.json mtime ($stats_mtime) is older than newest source mtime ($newest_source_mtime)"
fi

# =====================================================================
# (c) idempotent: running again succeeds and re-produces both artifacts
# =====================================================================

run2_output="$("$REINDEX" "$TMP_STORE" 2>&1)"
run2_status=$?
if [ "$run2_status" -eq 0 ] && [ -f "$TMP_STORE/index.json" ] && [ -f "$TMP_STORE/stats.json" ]; then
  pass "reindex.sh is idempotent — a second run exits 0 and both artifacts still exist"
else
  fail "reindex.sh second run failed (exit $run2_status) or an artifact disappeared"
fi

# =====================================================================
# (d) --quiet suppresses stdout, stderr still passes through failures
# =====================================================================

TMP_STORE_QUIET="$(mktemp -d 2>/dev/null || mktemp -d -t 'reindex-test-quiet')"
cp -R "$FIXTURE_STORE/." "$TMP_STORE_QUIET/"
rm -f "$TMP_STORE_QUIET/index.json" "$TMP_STORE_QUIET/stats.json"

quiet_stdout="$("$REINDEX" "$TMP_STORE_QUIET" --quiet 2>/dev/null)"
quiet_status=$?

if [ "$quiet_status" -eq 0 ] && [ -z "$quiet_stdout" ]; then
  pass "reindex.sh --quiet prints nothing on stdout"
else
  fail "reindex.sh --quiet exited $quiet_status or printed stdout: '$quiet_stdout'"
fi

if [ -f "$TMP_STORE_QUIET/index.json" ] && [ -f "$TMP_STORE_QUIET/stats.json" ]; then
  pass "reindex.sh --quiet still produced both artifacts"
else
  fail "reindex.sh --quiet did not produce both artifacts"
fi

rm -rf "$TMP_STORE_QUIET"

# =====================================================================
# (e) missing people/ exits non-zero
# =====================================================================

TMP_STORE_NOPEOPLE="$(mktemp -d 2>/dev/null || mktemp -d -t 'reindex-test-nopeople')"
mkdir -p "$TMP_STORE_NOPEOPLE/interactions"

nopeople_output="$("$REINDEX" "$TMP_STORE_NOPEOPLE" 2>&1)"
nopeople_status=$?

if [ "$nopeople_status" -ne 0 ]; then
  pass "reindex.sh exits non-zero when people/ is missing"
else
  fail "reindex.sh exited 0 despite a missing people/ directory"
fi

rm -rf "$TMP_STORE_NOPEOPLE"

# --- committed fixture dir must not have gained index.json/stats.json ---
if [ -f "$FIXTURE_STORE/index.json" ] || [ -f "$FIXTURE_STORE/stats.json" ]; then
  fail "packages/core/fixtures/store gained index.json/stats.json — the fixture dir must stay pristine (test must run against a temp copy)"
else
  pass "committed fixture store has no index.json/stats.json (test ran against a temp copy, as required)"
fi

summary_and_exit
