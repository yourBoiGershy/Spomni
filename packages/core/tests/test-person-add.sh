#!/usr/bin/env bash
# packages/core/tests/test-person-add.sh
#
# Covers packages/core/scripts/person-add.sh:
#   1. happy path — creates people/<slug>.md (kebab-cased name), prints
#      "person-add: created people/<slug>.md", store still validates clean.
#   2. an untagged --fact gets **[told-by-user]** prepended; a --fact with
#      its own provenance marker is kept verbatim.
#   3. --tier/--tier-source and --kind/--kind-source land in frontmatter
#      (kind_note/kind_updated written too, per the contract).
#   4. duplicate slug refusal — exit 3, message points at person-merge.sh,
#      the existing file is untouched.
#   5. invalid-input rollback — a second person whose name kebab-cases to an
#      existing slug (via --slug to a different filename) trips the
#      duplicate-slug validator rule; the just-written file is deleted
#      again and exit is 1 (never leaves an invalid file behind).
#   6. --tier without --tier-source and --kind without --kind-source are
#      usage errors (exit 1, nothing written).
#
# bash 3.2 portable (no associative arrays, no mapfile). Self-contained
# temp dirs; scaffolds via init-store.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PERSON_ADD="$REPO_ROOT/packages/core/scripts/person-add.sh"
INIT_STORE="$REPO_ROOT/packages/core/scripts/init-store.sh"
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
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'person-add-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  printf '%s\n' "$dir"
}

if [ ! -x "$PERSON_ADD" ]; then
  echo "SKIP: $PERSON_ADD not found or not executable — cannot run person-add tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, person-add.sh missing"
  exit 1
fi

scratch="$(new_scratch_dir)"
store="$scratch/store"
"$INIT_STORE" "$store" > /dev/null 2>&1 || {
  echo "FAIL: init-store.sh could not scaffold the test store"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
}

# ---------------------------------------------------------------------------
# assertion 1: happy path
# ---------------------------------------------------------------------------

out1="$("$PERSON_ADD" "$store" --name "Dana Whitfield" --tag fintech --tag college-friend --fact "Moved to Berlin for a new role" 2>&1)"
status1=$?

if [ "$status1" -eq 0 ] \
  && printf '%s' "$out1" | grep -qF "person-add: created people/dana-whitfield.md" \
  && [ -f "$store/people/dana-whitfield.md" ]
then
  pass "happy path creates people/dana-whitfield.md and prints the created line"
else
  fail "happy path did not create the person as expected (exit=$status1)"
  echo "$out1"
fi

validate_out1="$("$VALIDATOR" "$store" 2>&1)"
validate_status1=$?
if [ "$validate_status1" -eq 0 ]; then
  pass "store validates clean after person-add"
else
  fail "store failed validation after person-add (exit=$validate_status1)"
  echo "$validate_out1"
fi

if grep -qxF "schema_version: 1.4.0" "$store/people/dana-whitfield.md" \
  && grep -qxF "name: Dana Whitfield" "$store/people/dana-whitfield.md" \
  && grep -qxF "tags: [fintech, college-friend]" "$store/people/dana-whitfield.md"
then
  pass "frontmatter carries schema_version 1.4.0, name, and the tags list"
else
  fail "frontmatter fields missing or wrong in people/dana-whitfield.md"
  cat "$store/people/dana-whitfield.md"
fi

# ---------------------------------------------------------------------------
# assertion 2: fact provenance — untagged gets **[told-by-user]**, tagged
# stays verbatim
# ---------------------------------------------------------------------------

if grep -qF -- "- **[told-by-user]** Moved to Berlin for a new role" "$store/people/dana-whitfield.md"; then
  pass "untagged --fact got **[told-by-user]** prepended"
else
  fail "untagged --fact did not get the told-by-user marker"
  cat "$store/people/dana-whitfield.md"
fi

out2="$("$PERSON_ADD" "$store" --name "Aiko Example" --fact "**[inferred-from-thread]** Mentioned a job change in chat (2026-08-29)" 2>&1)"
status2=$?
if [ "$status2" -eq 0 ] \
  && grep -qF -- "- **[inferred-from-thread]** Mentioned a job change in chat (2026-08-29)" "$store/people/aiko-example.md" \
  && ! grep -qF -- "**[told-by-user]** **[inferred-from-thread]**" "$store/people/aiko-example.md"
then
  pass "--fact with its own provenance marker is kept verbatim"
else
  fail "tagged --fact was not kept verbatim (exit=$status2)"
  echo "$out2"
  cat "$store/people/aiko-example.md" 2>/dev/null
fi

if grep -qxF -- "- _none_" "$store/people/aiko-example.md" && grep -qxF "_none_" "$store/people/aiko-example.md"; then
  pass "empty sections carry the _none_ shape"
else
  fail "empty sections do not carry the _none_ shape"
  cat "$store/people/aiko-example.md" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# assertion 3: tier + kind fields
# ---------------------------------------------------------------------------

out3="$("$PERSON_ADD" "$store" --name "Kind Tier Person" --tier close --tier-source stated-by-user --kind friend --kind-source derived 2>&1)"
status3=$?
f3="$store/people/kind-tier-person.md"
if [ "$status3" -eq 0 ] \
  && grep -qxF "tier: close" "$f3" \
  && grep -qxF "tier_source: stated-by-user" "$f3" \
  && grep -qxF "kind: friend" "$f3" \
  && grep -qxF "kind_source: derived" "$f3" \
  && grep -q "^kind_note: " "$f3" \
  && grep -qE "^kind_updated: [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$f3"
then
  pass "--tier/--tier-source and --kind/--kind-source land in frontmatter with kind_note/kind_updated"
else
  fail "tier/kind fields not written as expected (exit=$status3)"
  echo "$out3"
  cat "$f3" 2>/dev/null
fi

validate_out3="$("$VALIDATOR" "$store" 2>&1)"
if [ $? -eq 0 ]; then
  pass "store still validates clean after the tier+kind person"
else
  fail "store failed validation after the tier+kind person"
  echo "$validate_out3"
fi

# ---------------------------------------------------------------------------
# assertion 4: duplicate slug refusal (exit 3, points at person-merge.sh)
# ---------------------------------------------------------------------------

before4="$(cat "$store/people/dana-whitfield.md")"
out4="$("$PERSON_ADD" "$store" --name "Dana Whitfield" 2>&1)"
status4=$?
after4="$(cat "$store/people/dana-whitfield.md")"

if [ "$status4" -eq 3 ] \
  && printf '%s' "$out4" | grep -qF "person-merge.sh" \
  && [ "$before4" = "$after4" ]
then
  pass "duplicate slug refused (exit 3, message points at person-merge.sh, file untouched)"
else
  fail "duplicate slug not refused as expected (exit=$status4)"
  echo "$out4"
fi

# ---------------------------------------------------------------------------
# assertion 5: invalid-input rollback — kebab-name collision under a
# different filename trips the validator's duplicate-slug rule; the written
# file must be deleted again, exit 1.
# ---------------------------------------------------------------------------

out5="$("$PERSON_ADD" "$store" --name "Dana Whitfield" --slug dana-whitfield-two 2>&1)"
status5=$?

if [ "$status5" -eq 1 ] \
  && [ ! -e "$store/people/dana-whitfield-two.md" ] \
  && printf '%s' "$out5" | grep -qF "FAIL: person-add refused"
then
  pass "validation failure rolls back: file deleted again, exit 1"
else
  fail "validation failure did not roll back as expected (exit=$status5)"
  echo "$out5"
  ls "$store/people"
fi

validate_out5="$("$VALIDATOR" "$store" 2>&1)"
if [ $? -eq 0 ]; then
  pass "store validates clean after the rolled-back attempt"
else
  fail "store left invalid after the rolled-back attempt"
  echo "$validate_out5"
fi

# ---------------------------------------------------------------------------
# assertion 6: pairing usage errors — nothing written
# ---------------------------------------------------------------------------

out6a="$("$PERSON_ADD" "$store" --name "Pair Fail A" --tier close 2>&1)"
status6a=$?
out6b="$("$PERSON_ADD" "$store" --name "Pair Fail B" --kind friend 2>&1)"
status6b=$?

if [ "$status6a" -eq 1 ] && [ "$status6b" -eq 1 ] \
  && [ ! -e "$store/people/pair-fail-a.md" ] && [ ! -e "$store/people/pair-fail-b.md" ]
then
  pass "--tier without --tier-source and --kind without --kind-source are usage errors, nothing written"
else
  fail "pairing usage errors not enforced (exit a=$status6a b=$status6b)"
  echo "$out6a"
  echo "$out6b"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
