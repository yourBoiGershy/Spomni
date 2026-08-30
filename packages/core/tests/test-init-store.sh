#!/usr/bin/env bash
# packages/core/tests/test-init-store.sh
#
# Covers packages/core/scripts/init-store.sh and
# packages/core/scripts/check-store-location.sh:
#   1. init-store.sh creates the four dirs + README.md + index.json/
#      stats.json under a fresh mktemp dir, and validate-store.sh passes.
#   2. init-store.sh is idempotent (re-running on the same dir stays exit 0
#      and doesn't clobber an existing README.md).
#   3. init-store.sh refuses (exit 2, "FAIL:") a store-dir that is the code
#      checkout itself.
#   4. check-store-location.sh exits 0 "OK:" for data/store under the repo.
#   5. check-store-location.sh exits 0 "OK:" for a plain mktemp dir.
#   6. check-store-location.sh exits 1 "FAIL:" for a dir inside
#      packages/ (inside the code checkout, not the data/ exception).
#   7. check-store-location.sh exits 1 "FAIL:" for a fake Dropbox/ path.
#   8. check-store-location.sh exits 0 "WARN:" for a path under a simulated
#      ~/Documents (HOME override).
#
# bash 3.2 portable (no associative arrays, no mapfile).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

INIT_STORE="$REPO_ROOT/packages/core/scripts/init-store.sh"
CHECK_LOCATION="$REPO_ROOT/packages/core/scripts/check-store-location.sh"
VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"

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

SCRATCH_DIRS=""

cleanup() {
  for d in $SCRATCH_DIRS; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

new_scratch_dir() {
  local dir
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'init-store-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  printf '%s\n' "$dir"
}

if [ ! -x "$INIT_STORE" ]; then
  echo "SKIP: $INIT_STORE not found or not executable — cannot run init-store tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, init-store.sh missing"
  exit 1
fi

if [ ! -x "$CHECK_LOCATION" ]; then
  echo "SKIP: $CHECK_LOCATION not found or not executable — cannot run check-store-location tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, check-store-location.sh missing"
  exit 1
fi

# ---------------------------------------------------------------------------
# assertion 1: init creates layout + validates
# ---------------------------------------------------------------------------

scratch1="$(new_scratch_dir)"
store1="$scratch1/store"
init_output1="$("$INIT_STORE" "$store1" 2>&1)"
init_status1=$?

if [ "$init_status1" -eq 0 ] \
  && [ -d "$store1/inbox" ] && [ -d "$store1/people" ] \
  && [ -d "$store1/interactions" ] && [ -d "$store1/wakeups" ] \
  && [ -f "$store1/README.md" ] && [ -f "$store1/index.json" ] \
  && [ -f "$store1/stats.json" ]
then
  pass "init-store.sh creates inbox/people/interactions/wakeups + README.md + index.json/stats.json"
else
  fail "init-store.sh did not create the expected layout (exit=$init_status1)"
  echo "$init_output1"
fi

if printf '%s' "$init_output1" | grep -qF "OK: store initialized"; then
  pass "init-store.sh prints an OK: store initialized line"
else
  fail "init-store.sh did not print an OK: store initialized line"
fi

validate_output1="$("$VALIDATOR" "$store1" 2>&1)"
validate_status1=$?
if [ "$validate_status1" -eq 0 ]; then
  pass "validate-store.sh exits 0 on the freshly initialized store"
else
  fail "validate-store.sh exited $validate_status1 (expected 0) on the freshly initialized store"
  echo "$validate_output1"
fi

# ---------------------------------------------------------------------------
# assertion 2: init is idempotent
# ---------------------------------------------------------------------------

readme_before="$(cat "$store1/README.md")"
init_output2="$("$INIT_STORE" "$store1" 2>&1)"
init_status2=$?
readme_after="$(cat "$store1/README.md")"

if [ "$init_status2" -eq 0 ]; then
  pass "init-store.sh re-run on the same dir exits 0 (idempotent)"
else
  fail "init-store.sh re-run on the same dir exited $init_status2 (expected 0)"
  echo "$init_output2"
fi

if [ "$readme_before" = "$readme_after" ]; then
  pass "init-store.sh re-run does not clobber an existing README.md"
else
  fail "init-store.sh re-run changed README.md contents"
fi

# ---------------------------------------------------------------------------
# assertion 3: init refuses a dir that is the code repo itself
# ---------------------------------------------------------------------------

refuse_output="$("$INIT_STORE" "$REPO_ROOT" 2>&1)"
refuse_status=$?

if [ "$refuse_status" -eq 2 ] && printf '%s' "$refuse_output" | grep -qF "FAIL:"; then
  pass "init-store.sh refuses (exit 2, FAIL:) the code checkout itself as a store-dir"
else
  fail "init-store.sh did not refuse the code checkout itself (exit=$refuse_status)"
  echo "$refuse_output"
fi

# ---------------------------------------------------------------------------
# assertion 4: check-store-location.sh passes for data/store under the repo
# ---------------------------------------------------------------------------

mkdir -p "$REPO_ROOT/data/store"
data_store_output="$("$CHECK_LOCATION" "$REPO_ROOT/data/store" 2>&1)"
data_store_status=$?
rmdir "$REPO_ROOT/data/store" 2>/dev/null || true

if [ "$data_store_status" -eq 0 ]; then
  pass "check-store-location.sh passes (exit 0) for data/store under the repo"
else
  fail "check-store-location.sh did not pass for data/store (exit=$data_store_status)"
  echo "$data_store_output"
fi

# ---------------------------------------------------------------------------
# assertion 5: check-store-location.sh passes for a plain mktemp dir
# ---------------------------------------------------------------------------

scratch5="$(new_scratch_dir)"
mktemp_output="$("$CHECK_LOCATION" "$scratch5" 2>&1)"
mktemp_status=$?

if [ "$mktemp_status" -eq 0 ] && printf '%s' "$mktemp_output" | grep -qF "OK:"; then
  pass "check-store-location.sh passes (OK:) for a plain mktemp dir"
else
  fail "check-store-location.sh did not pass for a plain mktemp dir (exit=$mktemp_status)"
  echo "$mktemp_output"
fi

# ---------------------------------------------------------------------------
# assertion 6: check-store-location.sh fails for a dir inside packages/
# ---------------------------------------------------------------------------

packages_output="$("$CHECK_LOCATION" "$REPO_ROOT/packages" 2>&1)"
packages_status=$?

if [ "$packages_status" -eq 1 ] && printf '%s' "$packages_output" | grep -qF "FAIL:"; then
  pass "check-store-location.sh fails (FAIL:) for a dir inside packages/ (inside the code checkout)"
else
  fail "check-store-location.sh did not fail for a dir inside packages/ (exit=$packages_status)"
  echo "$packages_output"
fi

# ---------------------------------------------------------------------------
# assertion 7: check-store-location.sh fails for a fake Dropbox/ path
# ---------------------------------------------------------------------------

scratch7="$(new_scratch_dir)"
dropbox_dir="$scratch7/Dropbox/spomni-store"
mkdir -p "$dropbox_dir"
dropbox_output="$("$CHECK_LOCATION" "$dropbox_dir" 2>&1)"
dropbox_status=$?

if [ "$dropbox_status" -eq 1 ] && printf '%s' "$dropbox_output" | grep -qF "FAIL:"; then
  pass "check-store-location.sh fails (FAIL:) for a fake Dropbox/ path"
else
  fail "check-store-location.sh did not fail for a fake Dropbox/ path (exit=$dropbox_status)"
  echo "$dropbox_output"
fi

# ---------------------------------------------------------------------------
# assertion 8: check-store-location.sh warns for a simulated ~/Documents
# path (HOME override)
# ---------------------------------------------------------------------------

scratch8="$(new_scratch_dir)"
fake_home="$scratch8/fake-home"
docs_dir="$fake_home/Documents/spomni-store"
mkdir -p "$docs_dir"
warn_output="$(HOME="$fake_home" "$CHECK_LOCATION" "$docs_dir" 2>&1)"
warn_status=$?

if [ "$warn_status" -eq 0 ] && printf '%s' "$warn_output" | grep -qF "WARN:"; then
  pass "check-store-location.sh warns (exit 0, WARN:) for a simulated ~/Documents path"
else
  fail "check-store-location.sh did not warn for a simulated ~/Documents path (exit=$warn_status)"
  echo "$warn_output"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
