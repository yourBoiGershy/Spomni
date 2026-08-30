#!/usr/bin/env bash
# packages/ingestion/tests/run-refresh-tests.sh
#
# Asserts packages/ingestion/scripts/refresh-person.sh against its spec
# (plan 36 A4, packages/ingestion/specs/currency.md "refresh-person.sh"):
#
#   refresh-person.sh <store-dir> <slug> [--data-dir <dir>] [--dry-run]
#
#   Env:
#     RA_REFRESH_PARSE_TEST=<file>  test-only: skip the model call, parse
#                                   <file> as a `claude -p --output-format
#                                   json` result whose `result` field is the
#                                   currency re-derivation JSON below.
#     RA_REFRESH_DRY_RUN=1          print the prompt, exit 0, no writes
#                                   (no model call at all).
#
#   Result schema:
#     {"schema_version":"1.0.0","slug":<slug>,
#      "facts":[{"provenance":"inferred-from-thread|inferred-public-web",
#                "text":<str>,"stale":<bool>}, ...],
#      "open_threads":[{"text":<str>,"as_of":"YYYY-MM-DD"}, ...],
#      "resolved":[{"text":<str>,"resolved_on":"YYYY-MM-DD"}, ...]}
#
#   Writes: only `inferred-*` Facts bullets are replaced wholesale by the
#   result's facts[] (stale ones rendered `- **[<tag>]** [stale] <text>`);
#   every `**[told-by-user]**` Facts bullet stays byte-identical; `##
#   Open threads` becomes exactly the result's open_threads[] rendered as
#   `- <text> (as-of <as_of>)`; `## Resolved` becomes the existing Resolved
#   bullets UNION the result's resolved[] rendered as
#   `- <text> (resolved <date>)` (H2 between Open threads and Personal
#   details, created if absent); frontmatter and Personal details are
#   untouched; `<data-dir>/ingestion/refresh.log` gains an append line;
#   stdout carries `refresh-person: <slug> facts=<n> stale=<n> open=<n>
#   resolved=<n>` (counts over the RESULT's own facts/open_threads/resolved
#   arrays: facts=len(facts), stale=count where stale==true,
#   open=len(open_threads), resolved=len(resolved)). Exit 4 on a result
#   whose facts[] carries a non-inferred-* provenance (schema-invalid for
#   this call — refresh-person never writes a told-by-user fact). Exit 2 on
#   a missing/absent slug (no slug argument, or a slug with no
#   people/<slug>.md file).
#
# Fixtures (packages/ingestion/tests/fixtures/refresh/), all synthetic PII
# (invented names, example.net-only where an address would appear — none
# used here since no identities.tsv is needed for this script):
#
#   store/ — a 2-person template store (people/, interactions/) copied
#     fresh into a tmp dir per case so no case can pollute another:
#       people/jordan-ellis.md — 2 told-by-user Facts bullets + 1
#         inferred-from-thread bullet (no [stale]), 1 Open threads bullet
#         with an (as-of ...) suffix, no Resolved section, Personal
#         details with one told-by-user bullet.
#       people/morgan-teague.md — a second, unrelated person never named
#         in any canned result below — a refresh-person run on
#         jordan-ellis must never touch this file (control).
#       interactions/2026-07-01-jordan-a.md,
#       interactions/2026-07-15-jordan-b.md,
#       interactions/2026-08-01-jordan-c.md — 3 interactions linking
#         [[jordan-ellis]], dated across the person's timeline (the input
#         refresh-person.sh is meant to read; this suite stubs the model
#         call entirely via RA_REFRESH_PARSE_TEST so the exact interaction
#         prose is not asserted on, only that a re-derivation call happens
#         against this slug).
#   claude-results/valid.json — a claude -p --output-format json result
#     (fenced ```json) whose result JSON re-derives jordan-ellis: the
#     existing inferred-from-thread fact re-stated with stale: true, one
#     new inferred-public-web fact (stale: false), one new open thread
#     (as_of 2026-08-01), and one resolved thread (the fixture's original
#     open thread text, resolved_on 2026-08-01) — exercises stale
#     placement, Open-threads rewrite, and Resolved creation in one pass.
#   claude-results/invalid.json — same slug, but facts[0].provenance is
#     "told-by-user" (illegal for this call) -> refresh-person.sh must
#     reject with exit 4 and leave the store untouched.
#
# A sibling worker is landing packages/ingestion/scripts/refresh-person.sh
# concurrently with this spec. If the script is absent, every case below is
# reported as script-not-landed, not as a generic failure.
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash. Same pass()/fail()/SUMMARY style as
# run-thread-tests.sh / run-merge-tests.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REFRESH_SCRIPT="$REPO_ROOT/packages/ingestion/scripts/refresh-person.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
FIXTURES="$REPO_ROOT/packages/ingestion/tests/fixtures/refresh"
TEMPLATE_STORE="$FIXTURES/store"
VALID_RESULT="$FIXTURES/claude-results/valid.json"
INVALID_RESULT="$FIXTURES/claude-results/invalid.json"

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

if [ ! -d "$TEMPLATE_STORE" ]; then
  echo "FAIL: fixtures missing at $TEMPLATE_STORE"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# script presence — checked before anything else so a missing sibling
# deliverable is reported precisely, not as a pile of generic FAILs.
# ---------------------------------------------------------------------------

if [ ! -f "$REFRESH_SCRIPT" ]; then
  echo "SKIP: $REFRESH_SCRIPT not found — refresh-person.sh has not landed yet (sibling worker in flight)."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, refresh-person.sh missing"
  exit 1
fi

if [ ! -x "$REFRESH_SCRIPT" ]; then
  echo "FAIL: $REFRESH_SCRIPT exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# fixture builder — fresh copy of the template store into
# $TMP_ROOT/<name>/data/store, isolated per case (data-dir default is
# <store-dir>/.., so DATA_DIR = the "data" directory, STORE = data/store).
# ---------------------------------------------------------------------------

build_case() {
  # $1 = case name -> prints "$DATA_DIR $STORE_DIR" for the caller to read
  local name="$1"
  local data_dir="$TMP_ROOT/$name/data"
  local store_dir="$data_dir/store"

  mkdir -p "$data_dir" "$data_dir/ingestion"
  cp -R "$TEMPLATE_STORE" "$store_dir"

  printf '%s %s' "$data_dir" "$store_dir"
}

JORDAN_ORIGINAL="$TEMPLATE_STORE/people/jordan-ellis.md"
told_by_user_lines_orig="$(grep '\*\*\[told-by-user\]\*\*' "$JORDAN_ORIGINAL")"

# ===========================================================================
# Case A: the real run — every content assertion.
# ===========================================================================

echo ""
echo "--- real run: content assertions ---"

read -r A_DATA A_STORE <<EOF
$(build_case "case-a-real-run")
EOF

JORDAN_FILE="$A_STORE/people/jordan-ellis.md"
MORGAN_FILE="$A_STORE/people/morgan-teague.md"
MORGAN_BACKUP="$TMP_ROOT/morgan-backup.md"
cp "$MORGAN_FILE" "$MORGAN_BACKUP"

a_output="$(RA_REFRESH_PARSE_TEST="$VALID_RESULT" "$REFRESH_SCRIPT" "$A_STORE" jordan-ellis --data-dir "$A_DATA" 2>&1)"
a_status=$?

if [ "$a_status" -eq 0 ]; then
  pass "case A: real run exits 0"
else
  fail "case A: real run exited $a_status (expected 0): $a_output"
fi

# --- summary line ---
if printf '%s' "$a_output" | grep -qE '^refresh-person: jordan-ellis facts=2 stale=1 open=1 resolved=1$'; then
  pass "case A: summary line 'refresh-person: jordan-ellis facts=2 stale=1 open=1 resolved=1'"
else
  fail "case A: summary line missing or malformed, got: $a_output"
fi

# --- told-by-user Facts bullets byte-identical ---
if [ -f "$JORDAN_FILE" ]; then
  told_by_user_lines_after="$(grep '\*\*\[told-by-user\]\*\*' "$JORDAN_FILE")"
  if [ "$told_by_user_lines_after" = "$told_by_user_lines_orig" ]; then
    pass "case A: told-by-user Facts bullets are byte-identical after refresh"
  else
    fail "case A: told-by-user Facts bullets changed"
    diff <(printf '%s\n' "$told_by_user_lines_orig") <(printf '%s\n' "$told_by_user_lines_after")
  fi
else
  fail "case A: jordan-ellis.md missing after refresh"
fi

# --- inferred fact re-rendered with [stale] immediately after the tag ---
if grep -qxF -- '- **[inferred-from-thread]** [stale] Seems to be prepping for a conference talk' "$JORDAN_FILE"; then
  pass "case A: inferred-from-thread fact re-rendered with [stale] after the provenance tag"
else
  fail "case A: expected stale inferred-from-thread bullet not found"
  [ -f "$JORDAN_FILE" ] && cat "$JORDAN_FILE"
fi

# --- new (non-stale) inferred fact rendered without [stale] ---
if grep -qxF -- '- **[inferred-public-web]** Fixture Robotics closed a seed round in 2026' "$JORDAN_FILE"; then
  pass "case A: new non-stale inferred-public-web fact rendered without [stale]"
else
  fail "case A: expected new inferred-public-web bullet not found"
fi

# --- Open threads rewritten to exactly the result's set, with (as-of ...) ---
open_section="$(awk '/^## Open threads$/{f=1;next}/^## /{f=0}f' "$JORDAN_FILE")"
if printf '%s\n' "$open_section" | grep -qxF -- '- Confirm details of the seed round announcement (as-of 2026-08-01)'; then
  pass "case A: Open threads carries the new bullet rendered '- <text> (as-of <as_of>)'"
else
  fail "case A: Open threads missing the expected new bullet"
  echo "$open_section"
fi

if printf '%s\n' "$open_section" | grep -qF 'Asked about the conference talk deck'; then
  fail "case A: the original open thread (now resolved) is still listed under Open threads"
else
  pass "case A: the original (now-resolved) open thread no longer appears under Open threads"
fi

# --- Resolved section created in the right position, with the union bullet ---
section_headings="$(grep -n '^## ' "$JORDAN_FILE")"
openthreads_hdr="$(printf '%s\n' "$section_headings" | awk -F: '$0 ~ /## Open threads$/ {print $1; exit}')"
resolved_hdr="$(printf '%s\n' "$section_headings" | awk -F: '$0 ~ /## Resolved$/ {print $1; exit}')"
personaldetails_hdr="$(printf '%s\n' "$section_headings" | awk -F: '$0 ~ /## Personal details$/ {print $1; exit}')"

if [ -n "$resolved_hdr" ] && [ -n "$openthreads_hdr" ] && [ -n "$personaldetails_hdr" ] \
  && [ "$resolved_hdr" -gt "$openthreads_hdr" ] && [ "$resolved_hdr" -lt "$personaldetails_hdr" ]; then
  pass "case A: ## Resolved was created between Open threads and Personal details"
else
  fail "case A: ## Resolved missing or mispositioned (open=$openthreads_hdr resolved=$resolved_hdr personal=$personaldetails_hdr)"
fi

if grep -qxF -- '- Asked about the conference talk deck (resolved 2026-08-01)' "$JORDAN_FILE"; then
  pass "case A: Resolved carries the result's resolved bullet '- <text> (resolved <date>)'"
else
  fail "case A: Resolved missing the expected bullet"
fi

# --- frontmatter untouched ---
orig_frontmatter="$(sed -n '/^---$/,/^---$/p' "$JORDAN_ORIGINAL")"
new_frontmatter="$(sed -n '/^---$/,/^---$/p' "$JORDAN_FILE")"
if [ "$orig_frontmatter" = "$new_frontmatter" ]; then
  pass "case A: frontmatter is untouched"
else
  fail "case A: frontmatter changed"
  diff <(printf '%s\n' "$orig_frontmatter") <(printf '%s\n' "$new_frontmatter")
fi

# --- Personal details untouched ---
orig_personal="$(awk '/^## Personal details$/{f=1;next}f' "$JORDAN_ORIGINAL")"
new_personal="$(awk '/^## Personal details$/{f=1;next}f' "$JORDAN_FILE")"
if [ "$orig_personal" = "$new_personal" ]; then
  pass "case A: Personal details is untouched"
else
  fail "case A: Personal details changed"
  diff <(printf '%s\n' "$orig_personal") <(printf '%s\n' "$new_personal")
fi

# --- morgan-teague.md (control person) never touched ---
if diff -q "$MORGAN_BACKUP" "$MORGAN_FILE" >/dev/null 2>&1; then
  pass "case A: the unrelated control person (morgan-teague.md) is untouched"
else
  fail "case A: morgan-teague.md was modified by a refresh run scoped to jordan-ellis"
fi

# --- refresh.log gained a line ---
REFRESH_LOG="$A_DATA/ingestion/refresh.log"
if [ -f "$REFRESH_LOG" ] && grep -q "jordan-ellis" "$REFRESH_LOG"; then
  pass "case A: <data-dir>/ingestion/refresh.log gained a line naming jordan-ellis"
else
  fail "case A: refresh.log missing or has no jordan-ellis line"
  [ -f "$REFRESH_LOG" ] && cat "$REFRESH_LOG"
fi

# --- validate-store.sh clean after ---
if [ -x "$VALIDATOR" ]; then
  validate_output="$("$VALIDATOR" "$A_STORE" 2>&1)"
  validate_status=$?
  if [ "$validate_status" -eq 0 ]; then
    pass "case A: validate-store.sh is clean against the post-refresh store"
  else
    fail "case A: validate-store.sh exited $validate_status (expected 0)"
    echo "$validate_output"
  fi
else
  fail "case A: cannot check validate-store.sh: $VALIDATOR not found or not executable"
fi

# ===========================================================================
# Case B: rerun is idempotent (byte-identical to the first result).
# ===========================================================================

echo ""
echo "--- rerun idempotence ---"

FIRST_RUN_SNAPSHOT="$TMP_ROOT/jordan-after-first-run.md"
cp "$JORDAN_FILE" "$FIRST_RUN_SNAPSHOT"

rerun_output="$(RA_REFRESH_PARSE_TEST="$VALID_RESULT" "$REFRESH_SCRIPT" "$A_STORE" jordan-ellis --data-dir "$A_DATA" 2>&1)"
rerun_status=$?

if [ "$rerun_status" -eq 0 ]; then
  pass "case B: rerun with the same result exits 0"
else
  fail "case B: rerun exited $rerun_status (expected 0): $rerun_output"
fi

if diff -q "$FIRST_RUN_SNAPSHOT" "$JORDAN_FILE" >/dev/null 2>&1; then
  pass "case B: rerunning the same canned result is idempotent (byte-identical)"
else
  fail "case B: rerun produced a different file than the first run"
  diff "$FIRST_RUN_SNAPSHOT" "$JORDAN_FILE"
fi

# ===========================================================================
# Case C: --dry-run leaves every file byte-identical.
# ===========================================================================

echo ""
echo "--- --dry-run writes nothing ---"

read -r DRY_DATA DRY_STORE <<EOF
$(build_case "case-c-dry-run")
EOF

DRY_BACKUP="$TMP_ROOT/case-c-dry-run-backup"
cp -R "$DRY_DATA" "$DRY_BACKUP"

dry_output="$(RA_REFRESH_PARSE_TEST="$VALID_RESULT" "$REFRESH_SCRIPT" "$DRY_STORE" jordan-ellis --data-dir "$DRY_DATA" --dry-run 2>&1)"
dry_status=$?

if [ "$dry_status" -eq 0 ]; then
  pass "case C: --dry-run exits 0"
else
  fail "case C: --dry-run exited $dry_status (expected 0): $dry_output"
fi

dry_diff="$(diff -r "$DRY_BACKUP" "$DRY_DATA" 2>&1)"
if [ -z "$dry_diff" ]; then
  pass "case C: --dry-run leaves every file byte-identical (no writes)"
else
  fail "case C: --dry-run wrote something to disk"
  echo "$dry_diff"
fi

# ===========================================================================
# Case D: RA_REFRESH_DRY_RUN=1 prints a prompt, no model call, no writes.
# ===========================================================================

echo ""
echo "--- RA_REFRESH_DRY_RUN=1 (prompt-only, no model call) ---"

read -r ENVDRY_DATA ENVDRY_STORE <<EOF
$(build_case "case-d-env-dry-run")
EOF

ENVDRY_BACKUP="$TMP_ROOT/case-d-env-dry-run-backup"
cp -R "$ENVDRY_DATA" "$ENVDRY_BACKUP"

envdry_output="$(RA_REFRESH_DRY_RUN=1 "$REFRESH_SCRIPT" "$ENVDRY_STORE" jordan-ellis --data-dir "$ENVDRY_DATA" 2>&1)"
envdry_status=$?

if [ "$envdry_status" -eq 0 ]; then
  pass "case D: RA_REFRESH_DRY_RUN=1 exits 0"
else
  fail "case D: RA_REFRESH_DRY_RUN=1 exited $envdry_status (expected 0): $envdry_output"
fi

if [ -n "$envdry_output" ]; then
  pass "case D: RA_REFRESH_DRY_RUN=1 prints a (non-empty) prompt"
else
  fail "case D: RA_REFRESH_DRY_RUN=1 produced no output"
fi

envdry_diff="$(diff -r "$ENVDRY_BACKUP" "$ENVDRY_DATA" 2>&1)"
if [ -z "$envdry_diff" ]; then
  pass "case D: RA_REFRESH_DRY_RUN=1 writes nothing to disk"
else
  fail "case D: RA_REFRESH_DRY_RUN=1 wrote something to disk"
  echo "$envdry_diff"
fi

# ===========================================================================
# Case E: invalid result -> exit 4, file untouched.
# ===========================================================================

echo ""
echo "--- invalid result JSON -> exit 4, no writes ---"

read -r E_DATA E_STORE <<EOF
$(build_case "case-e-invalid-result")
EOF

E_JORDAN_FILE="$E_STORE/people/jordan-ellis.md"
E_BACKUP="$TMP_ROOT/case-e-jordan-backup.md"
cp "$E_JORDAN_FILE" "$E_BACKUP"

invalid_output="$(RA_REFRESH_PARSE_TEST="$INVALID_RESULT" "$REFRESH_SCRIPT" "$E_STORE" jordan-ellis --data-dir "$E_DATA" 2>&1)"
invalid_status=$?

if [ "$invalid_status" -eq 4 ]; then
  pass "case E: invalid result (told-by-user in facts[]) exits 4"
else
  fail "case E: expected exit 4, got $invalid_status: $invalid_output"
fi

if diff -q "$E_BACKUP" "$E_JORDAN_FILE" >/dev/null 2>&1; then
  pass "case E: jordan-ellis.md is untouched after an invalid result"
else
  fail "case E: jordan-ellis.md was modified despite an invalid result"
  diff "$E_BACKUP" "$E_JORDAN_FILE"
fi

# ===========================================================================
# Case F: missing slug -> exit 2 (no slug argument at all).
# ===========================================================================

echo ""
echo "--- missing slug argument -> exit 2 ---"

read -r F_DATA F_STORE <<EOF
$(build_case "case-f-no-slug-arg")
EOF

noargs_output="$(RA_REFRESH_PARSE_TEST="$VALID_RESULT" "$REFRESH_SCRIPT" "$F_STORE" --data-dir "$F_DATA" 2>&1)"
noargs_status=$?
if [ "$noargs_status" -eq 2 ]; then
  pass "case F: no slug argument exits 2"
else
  fail "case F: expected exit 2 for a missing slug argument, got $noargs_status: $noargs_output"
fi

# ===========================================================================
# Case G: slug with no people/<slug>.md file -> exit 2.
# ===========================================================================

echo ""
echo "--- unknown slug -> exit 2 ---"

read -r G_DATA G_STORE <<EOF
$(build_case "case-g-unknown-slug")
EOF

unknown_output="$(RA_REFRESH_PARSE_TEST="$VALID_RESULT" "$REFRESH_SCRIPT" "$G_STORE" ghost-person --data-dir "$G_DATA" 2>&1)"
unknown_status=$?
if [ "$unknown_status" -eq 2 ]; then
  pass "case G: unknown slug (no people/<slug>.md) exits 2"
else
  fail "case G: expected exit 2 for an unknown slug, got $unknown_status: $unknown_output"
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
