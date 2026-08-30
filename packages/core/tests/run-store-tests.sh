#!/usr/bin/env bash
# packages/core/tests/run-store-tests.sh
#
# Asserts that packages/core/scripts/validate-store.sh:
#   1. passes (exit 0) against the clean fixture store
#      (packages/core/fixtures/store/)
#   2. fails (exit 1) against the seeded-corruption fixture store
#      (packages/core/fixtures/corrupted/) and reports every one of the 5
#      seeded corruptions (matched by the filename of the corrupted file).
#
# bash 3.2 portable (no associative arrays, no mapfile) — this must run
# under macOS's stock /bin/bash. Resolves all paths relative to the repo
# root, so it can be invoked from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

VALIDATOR="$REPO_ROOT/packages/core/scripts/validate-store.sh"
CLEAN_STORE="$REPO_ROOT/packages/core/fixtures/store"
CORRUPTED_STORE="$REPO_ROOT/packages/core/fixtures/corrupted"

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

# --- validator must exist ---
if [ ! -f "$VALIDATOR" ]; then
  echo "SKIP: $VALIDATOR not found — cannot run store tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, validator missing"
  exit 1
fi

if [ ! -x "$VALIDATOR" ]; then
  echo "FAIL: $VALIDATOR exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

# --- assertion 1: clean store passes ---
if [ ! -d "$CLEAN_STORE" ]; then
  fail "clean fixture store missing at $CLEAN_STORE"
else
  clean_output="$("$VALIDATOR" "$CLEAN_STORE" 2>&1)"
  clean_status=$?
  if [ "$clean_status" -eq 0 ]; then
    pass "validate-store.sh exits 0 on the clean fixture store"
  else
    fail "validate-store.sh exited $clean_status (expected 0) on the clean fixture store"
    echo "$clean_output"
  fi
fi

# --- assertion 2: corrupted store fails ---
if [ ! -d "$CORRUPTED_STORE" ]; then
  fail "corrupted fixture store missing at $CORRUPTED_STORE"
  corrupted_output=""
  corrupted_status=""
else
  corrupted_output="$("$VALIDATOR" "$CORRUPTED_STORE" 2>&1)"
  corrupted_status=$?
  if [ "$corrupted_status" -eq 1 ]; then
    pass "validate-store.sh exits 1 on the corrupted fixture store"
  else
    fail "validate-store.sh exited $corrupted_status (expected 1) on the corrupted fixture store"
  fi
fi

# --- assertion 3: every seeded corruption is reported, by filename ---
# One entry per seeded corruption (see fixtures/corrupted/README.md).
# The duplicate-slug corruption spans two files; both must be mentioned.
seeded_files="
2026-08-15-priya-nandakumar.md:broken link to a nonexistent person
jordan-abernathy.md:malformed frontmatter (missing closing ---)
2026-08-10-orphan.md:orphan interaction with no linked people
leo-fenwick.md:duplicate person slug (leo-fenwick)
leo-fenwick-duplicate.md:duplicate person slug (leo-fenwick)
2026-09-05-priya-nandakumar.md:invalid wakeup status
"

if [ -n "${corrupted_output:-}" ]; then
  # `<<<` (here-string) runs the loop in the current shell under bash 3.2
  # (unlike piping into `while`, which forks a subshell), so PASS_COUNT/
  # FAIL_COUNT updates inside the loop are visible afterward.
  while IFS=':' read -r fname desc; do
    [ -z "$fname" ] && continue
    if printf '%s' "$corrupted_output" | grep -qF -- "$fname"; then
      pass "output mentions $fname ($desc)"
    else
      fail "output does not mention $fname ($desc)"
    fi
  done <<< "$seeded_files"
else
  fail "no output captured from validate-store.sh against the corrupted store — cannot check seeded corruptions"
fi

# ---------------------------------------------------------------------------
# assertion 4: plan-11 contract fixtures (profile.md + wakeup 1.0.0/1.1.0)
#
# Each entry below is a standalone mini-store under packages/core/fixtures/
# (its own people/, interactions/, wakeups/, plus a profile.md at the store
# root) isolating exactly one profile.md or wakeup rule from
# packages/core/contracts/profile.md and wakeup.md@1.1.0. "valid" fixtures
# must pass (exit 0); "invalid" fixtures must fail (exit 1).
# ---------------------------------------------------------------------------

plan11_fixtures="
profile-valid:0:profile.md — tagged bullets in every section, birthday — all and job-change — [[slug]] opt-outs
profile-invalid-untagged-bullet:1:profile.md — untagged Priorities bullet
profile-invalid-malformed-optout:1:profile.md — malformed Signal opt-outs grammar
profile-invalid-style-notes-stated:1:profile.md — stated-by-user bullet under Style notes
wakeup-1.0.0-valid:0:wakeup schema_version 1.0.0, no 1.1.0 fields
wakeup-1.1.0-fired-acted-on:0:wakeup 1.1.0 fired with fired-on + acted-on: true
wakeup-1.1.0-dismissed-valid:0:wakeup 1.1.0 dismissed with dismiss-reason: not-this-signal-type
wakeup-1.1.0-snooze-count:0:wakeup 1.1.0 with snooze-count: 2
wakeup-1.1.0-invalid-dismissed-no-reason:1:wakeup 1.1.0 dismissed without dismiss-reason
wakeup-1.1.0-invalid-dismissed-bad-reason:1:wakeup 1.1.0 dismissed with a dismiss-reason outside the enum
wakeup-1.2.0-valid-proposal:0:wakeup 1.2.0 event-proposal with a well-formed proposed-event mapping
wakeup-1.2.0-invalid-created-without-confirmed:1:wakeup 1.2.0 created-event-id set without confirmed-on — validator-checkable proof of the 1.2.0 invariant
wakeup-1.2.0-invalid-proposal-no-proposed-event:1:wakeup 1.2.0 kind: event-proposal missing its required proposed-event mapping
"

while IFS=':' read -r fixture_name expected_status desc; do
  [ -z "$fixture_name" ] && continue
  fixture_dir="$REPO_ROOT/packages/core/fixtures/$fixture_name"
  if [ ! -d "$fixture_dir" ]; then
    fail "fixture missing: $fixture_dir ($desc)"
    continue
  fi
  fixture_output="$("$VALIDATOR" "$fixture_dir" 2>&1)"
  fixture_status=$?
  if [ "$fixture_status" -eq "$expected_status" ]; then
    pass "$fixture_name exits $expected_status as expected ($desc)"
  else
    fail "$fixture_name exited $fixture_status (expected $expected_status) ($desc)"
    echo "$fixture_output"
  fi
done <<< "$plan11_fixtures"

# ---------------------------------------------------------------------------
# assertion 5: plan-30 kind-field write path (person-set-kind.sh) — round
# trip, both refusal shapes, and re-stating over a derived kind. Operates on
# a scratch copy of fixtures/store/ (never the committed fixture).
# ---------------------------------------------------------------------------

PLAN30_KIND_SCRIPT="$REPO_ROOT/packages/core/scripts/person-set-kind.sh"
PLAN30_BUILD_INDEX="$REPO_ROOT/packages/core/scripts/build-index.sh"
PLAN30_SOURCE_STORE="$REPO_ROOT/packages/core/fixtures/store"

PLAN30_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$PLAN30_TMP_ROOT"' EXIT

echo ""
echo "--- plan 30: person-set-kind.sh round-trip + refusals ---"

KIND_STORE="$PLAN30_TMP_ROOT/kind-store"

if [ ! -x "$PLAN30_KIND_SCRIPT" ]; then
  fail "$PLAN30_KIND_SCRIPT not found or not executable"
elif [ ! -d "$PLAN30_SOURCE_STORE" ]; then
  fail "plan30 kind tests: source store fixture missing at $PLAN30_SOURCE_STORE"
else
  cp -R "$PLAN30_SOURCE_STORE" "$KIND_STORE"

  TARGET_PERSON="$KIND_STORE/people/aiko-tanaka.md"
  if [ ! -f "$TARGET_PERSON" ]; then
    fail "plan30 kind round-trip: fixture person people/aiko-tanaka.md missing"
  else
    before_snapshot="$PLAN30_TMP_ROOT/aiko-before.md"
    cp "$TARGET_PERSON" "$before_snapshot"

    set_output="$("$PLAN30_KIND_SCRIPT" "$KIND_STORE" aiko-tanaka --kind friend --note "met in college chemistry lab" --source stated-by-user --today 2026-08-29 2>&1)"
    set_status=$?

    if [ "$set_status" -eq 0 ]; then
      pass "person-set-kind.sh exits 0 on a valid stated-by-user write"
    else
      fail "person-set-kind.sh exited $set_status (expected 0) on a valid stated-by-user write: $set_output"
    fi

    if printf '%s' "$set_output" | grep -qF "set kind=friend source=stated-by-user for aiko-tanaka"; then
      pass "person-set-kind.sh prints the expected confirmation line"
    else
      fail "person-set-kind.sh did not print the expected confirmation line, got: $set_output"
    fi

    if grep -qxF "kind: friend" "$TARGET_PERSON" \
      && grep -qxF "kind_note: met in college chemistry lab" "$TARGET_PERSON" \
      && grep -qxF "kind_source: stated-by-user" "$TARGET_PERSON" \
      && grep -qxF "kind_updated: 2026-08-29" "$TARGET_PERSON"; then
      pass "person-set-kind.sh wrote all five kind fields with the expected values"
    else
      fail "person-set-kind.sh did not write the expected kind* field values"
      cat "$TARGET_PERSON"
    fi

    if grep -q '^kind_expires:' "$TARGET_PERSON"; then
      fail "person-set-kind.sh wrote a kind_expires line for a non-scheduling kind (should be omitted)"
    else
      pass "person-set-kind.sh omits kind_expires for a non-scheduling kind"
    fi

    diff_out="$(diff <(grep -v '^kind' "$before_snapshot") <(grep -v '^kind' "$TARGET_PERSON"))"
    if [ -z "$diff_out" ]; then
      pass "person-set-kind.sh leaves every non-kind* line byte-identical"
    else
      fail "person-set-kind.sh changed a non-kind* line"
      echo "$diff_out"
    fi

    derived_output="$("$PLAN30_KIND_SCRIPT" "$KIND_STORE" aiko-tanaka --kind unknown --note "guess" --source derived --today 2026-08-30 2>&1)"
    derived_status=$?
    if [ "$derived_status" -eq 2 ]; then
      pass "person-set-kind.sh exits 2 when a derived write targets a stated-by-user kind"
    else
      fail "person-set-kind.sh exited $derived_status (expected 2) on derived-over-stated refusal"
    fi
    if printf '%s' "$derived_output" | grep -qi "refusing"; then
      pass "person-set-kind.sh stderr mentions 'refusing' on derived-over-stated refusal"
    else
      fail "person-set-kind.sh did not mention 'refusing' in output: $derived_output"
    fi
    if grep -qxF "kind: friend" "$TARGET_PERSON" && grep -qxF "kind_source: stated-by-user" "$TARGET_PERSON"; then
      pass "person-set-kind.sh leaves the file untouched after a refused derived write"
    else
      fail "person-set-kind.sh mutated the file despite refusing the derived write"
    fi
  fi

  TARGET_PERSON2="$KIND_STORE/people/ayesha-malik.md"
  if [ ! -f "$TARGET_PERSON2" ]; then
    fail "plan30 kind tests: fixture person people/ayesha-malik.md missing"
  else
    sched_status_output="$("$PLAN30_KIND_SCRIPT" "$KIND_STORE" ayesha-malik --kind scheduling --note "dentist reminder" --source derived --today 2026-08-29 2>&1)"
    sched_status=$?
    if [ "$sched_status" -eq 2 ]; then
      pass "person-set-kind.sh exits 2 for --kind scheduling without --expires"
    else
      fail "person-set-kind.sh exited $sched_status (expected 2) for --kind scheduling without --expires: $sched_status_output"
    fi

    invalid_kind_output="$("$PLAN30_KIND_SCRIPT" "$KIND_STORE" ayesha-malik --kind bogus --note "x" --source derived --today 2026-08-29 2>&1)"
    invalid_kind_status=$?
    if [ "$invalid_kind_status" -eq 2 ]; then
      pass "person-set-kind.sh exits 2 for an invalid --kind value"
    else
      fail "person-set-kind.sh exited $invalid_kind_status (expected 2) for an invalid --kind value: $invalid_kind_output"
    fi

    "$PLAN30_KIND_SCRIPT" "$KIND_STORE" ayesha-malik --kind professional --note "colleague" --source derived --today 2026-08-29 > /dev/null 2>&1
    restate_output="$("$PLAN30_KIND_SCRIPT" "$KIND_STORE" ayesha-malik --kind professional --note "confirmed colleague" --source stated-by-user --today 2026-08-30 2>&1)"
    restate_status=$?
    if [ "$restate_status" -eq 0 ] && grep -qxF "kind_source: stated-by-user" "$TARGET_PERSON2"; then
      pass "person-set-kind.sh re-set to stated-by-user reads back kind_source: stated-by-user"
    else
      fail "person-set-kind.sh re-set to stated-by-user failed (exit $restate_status) or did not persist kind_source: $restate_output"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# assertion 6: plan-30 build-index.sh kind columns (reuses KIND_STORE from
# assertion 5, which already has aiko-tanaka kinded and several people
# untouched).
# ---------------------------------------------------------------------------

echo ""
echo "--- plan 30: build-index.sh kind columns ---"

if [ ! -x "$PLAN30_BUILD_INDEX" ]; then
  fail "$PLAN30_BUILD_INDEX not found or not executable"
elif ! command -v jq >/dev/null 2>&1; then
  fail "jq not found on PATH — cannot check build-index.sh kind columns"
elif [ ! -d "$KIND_STORE" ]; then
  fail "plan30 build-index tests: KIND_STORE from the person-set-kind tests is unavailable"
else
  index_output="$("$PLAN30_BUILD_INDEX" "$KIND_STORE" 2>&1)"
  index_status=$?
  index_file="$KIND_STORE/index.json"
  if [ "$index_status" -eq 0 ] && [ -f "$index_file" ]; then
    pass "build-index.sh runs cleanly against the kind-bearing store"
  else
    fail "build-index.sh exited $index_status or did not write index.json: $index_output"
  fi

  if [ -f "$index_file" ]; then
    kinded_kind="$(jq -r '."aiko-tanaka".kind' "$index_file")"
    kinded_source="$(jq -r '."aiko-tanaka".kind_source' "$index_file")"
    kinded_expires="$(jq -r '."aiko-tanaka".kind_expires' "$index_file")"
    if [ "$kinded_kind" = "friend" ] && [ "$kinded_source" = "stated-by-user" ] && [ "$kinded_expires" = "null" ]; then
      pass "index.json populates kind/kind_source/kind_expires for a kinded person"
    else
      fail "index.json kind columns wrong for aiko-tanaka: kind=$kinded_kind kind_source=$kinded_source kind_expires=$kinded_expires"
    fi

    unkinded_slug=""
    for candidate in beatrice-okonjo ben-whitmore chris-doyle; do
      if jq -e --arg s "$candidate" 'has($s)' "$index_file" > /dev/null 2>&1; then
        unkinded_slug="$candidate"
        break
      fi
    done
    if [ -n "$unkinded_slug" ]; then
      u_kind="$(jq -r --arg s "$unkinded_slug" '.[$s].kind' "$index_file")"
      u_source="$(jq -r --arg s "$unkinded_slug" '.[$s].kind_source' "$index_file")"
      u_expires="$(jq -r --arg s "$unkinded_slug" '.[$s].kind_expires' "$index_file")"
      if [ "$u_kind" = "null" ] && [ "$u_source" = "null" ] && [ "$u_expires" = "null" ]; then
        pass "index.json shows null kind columns for an unkinded person ($unkinded_slug)"
      else
        fail "index.json kind columns not null for unkinded $unkinded_slug: kind=$u_kind kind_source=$u_source kind_expires=$u_expires"
      fi
    else
      fail "plan30 build-index test: no unkinded candidate slug found in $index_file"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# assertion 7: plan-30 validate-store.sh rules — person kind fields,
# user-model.md pairing/axes, index/embeddings.jsonl. Each case is a
# throwaway minimal store built in PLAN30_TMP_ROOT (people/interactions/
# wakeups + exactly the file(s) under test).
# ---------------------------------------------------------------------------

echo ""
echo "--- plan 30: validate-store.sh kind / user-model / embeddings rules ---"

plan30_min_store() {
  mkdir -p "$1/people" "$1/interactions" "$1/wakeups"
}

plan30_assert_finding() {
  # $1 = case dir, $2 = expected exit status, $3 = grep pattern (or "" to
  # skip the content check), $4 = label
  local dir="$1" expected="$2" pattern="$3" label="$4"
  local out status
  out="$("$VALIDATOR" "$dir" 2>&1)"
  status=$?
  if [ "$status" -ne "$expected" ]; then
    fail "$label: validate-store.sh exited $status (expected $expected)"
    echo "$out"
    return
  fi
  if [ -n "$pattern" ] && ! printf '%s' "$out" | grep -q "$pattern"; then
    fail "$label: validate-store.sh output did not match /$pattern/"
    echo "$out"
    return
  fi
  pass "$label"
}

# --- person.md kind fields ---

C_KIND_BAD_VOCAB="$PLAN30_TMP_ROOT/case-kind-bad-vocab"
plan30_min_store "$C_KIND_BAD_VOCAB"
cat > "$C_KIND_BAD_VOCAB/people/test-person.md" <<'EOF'
---
schema_version: 1.0.0
name: Test Person
kind: bogus-kind
kind_note: test note
kind_source: stated-by-user
kind_updated: 2026-08-29
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_KIND_BAD_VOCAB" 1 "invalid kind" \
  "validate-store.sh flags a kind value outside the vocabulary"

C_KIND_NO_NOTE="$PLAN30_TMP_ROOT/case-kind-no-note"
plan30_min_store "$C_KIND_NO_NOTE"
cat > "$C_KIND_NO_NOTE/people/test-person.md" <<'EOF'
---
schema_version: 1.0.0
name: Test Person
kind: friend
kind_source: stated-by-user
kind_updated: 2026-08-29
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_KIND_NO_NOTE" 1 "missing required field: kind_note" \
  "validate-store.sh flags kind set without kind_note"

C_KIND_NOTE_ORPHAN="$PLAN30_TMP_ROOT/case-kind-note-orphan"
plan30_min_store "$C_KIND_NOTE_ORPHAN"
cat > "$C_KIND_NOTE_ORPHAN/people/test-person.md" <<'EOF'
---
schema_version: 1.0.0
name: Test Person
kind_note: orphan note
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_KIND_NOTE_ORPHAN" 1 "kind_note is set without kind" \
  "validate-store.sh flags kind_note present without kind"

C_KIND_SCHED_NO_EXPIRES="$PLAN30_TMP_ROOT/case-kind-sched-no-expires"
plan30_min_store "$C_KIND_SCHED_NO_EXPIRES"
cat > "$C_KIND_SCHED_NO_EXPIRES/people/test-person.md" <<'EOF'
---
schema_version: 1.0.0
name: Test Person
kind: scheduling
kind_note: dentist reminder
kind_source: derived
kind_updated: 2026-08-29
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_KIND_SCHED_NO_EXPIRES" 1 "requires a kind_expires date" \
  "validate-store.sh flags kind: scheduling without kind_expires"

# --- user-model.md ---

PLAN30_USER_MODEL_VALID="$REPO_ROOT/packages/core/fixtures/plan30/user-model-valid.md"

if [ ! -f "$PLAN30_USER_MODEL_VALID" ]; then
  fail "plan30 user-model tests: fixture missing at $PLAN30_USER_MODEL_VALID"
else
  C_UM_VALID="$PLAN30_TMP_ROOT/case-user-model-valid"
  plan30_min_store "$C_UM_VALID"
  cp "$PLAN30_USER_MODEL_VALID" "$C_UM_VALID/user-model.md"
  plan30_assert_finding "$C_UM_VALID" 0 "store clean" \
    "validate-store.sh accepts a valid confirmed user-model.md"

  C_UM_PAIRING="$PLAN30_TMP_ROOT/case-user-model-pairing-mismatch"
  plan30_min_store "$C_UM_PAIRING"
  sed -e 's/^status: confirmed$/status: draft/' -e 's/^confirmed_at: 2026-08-25$/confirmed_at: null/' -e 's/^revision: 1$/revision: 0/' \
    "$PLAN30_USER_MODEL_VALID" > "$C_UM_PAIRING/user-model.md"
  plan30_assert_finding "$C_UM_PAIRING" 1 "requires provenance: observed-from-behavior" \
    "validate-store.sh flags status: draft paired with provenance: stated-by-user"

  C_UM_WEIGHT="$PLAN30_TMP_ROOT/case-user-model-bad-weight"
  plan30_min_store "$C_UM_WEIGHT"
  sed -e 's/^- business: 0.3 —/- business: 1.5 —/' \
    "$PLAN30_USER_MODEL_VALID" > "$C_UM_WEIGHT/user-model.md"
  plan30_assert_finding "$C_UM_WEIGHT" 1 "weight out of range" \
    "validate-store.sh flags an Investment mix axis weight of 1.5"

  C_UM_MISSING_AXIS="$PLAN30_TMP_ROOT/case-user-model-missing-axis"
  plan30_min_store "$C_UM_MISSING_AXIS"
  grep -v '^- family:' "$PLAN30_USER_MODEL_VALID" > "$C_UM_MISSING_AXIS/user-model.md"
  plan30_assert_finding "$C_UM_MISSING_AXIS" 1 "missing required axis line: family" \
    "validate-store.sh flags a user-model.md missing the family axis line"
fi

# --- index/embeddings.jsonl ---

PLAN30_EMBEDDINGS_VALID="$REPO_ROOT/packages/core/fixtures/plan30/embeddings-valid.jsonl"

if [ ! -f "$PLAN30_EMBEDDINGS_VALID" ]; then
  fail "plan30 embeddings tests: fixture missing at $PLAN30_EMBEDDINGS_VALID"
else
  C_EMB_VALID="$PLAN30_TMP_ROOT/case-embeddings-valid"
  plan30_min_store "$C_EMB_VALID"
  cat > "$C_EMB_VALID/people/sample-person.md" <<'EOF'
---
schema_version: 1.0.0
name: Sample Person
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
  mkdir -p "$C_EMB_VALID/index"
  cp "$PLAN30_EMBEDDINGS_VALID" "$C_EMB_VALID/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_VALID" 0 "store clean" \
    "validate-store.sh accepts a valid embeddings.jsonl line"

  C_EMB_DIMS="$PLAN30_TMP_ROOT/case-embeddings-dims-mismatch"
  plan30_min_store "$C_EMB_DIMS"
  cp "$C_EMB_VALID/people/sample-person.md" "$C_EMB_DIMS/people/sample-person.md"
  mkdir -p "$C_EMB_DIMS/index"
  sed 's/"dims": 4/"dims": 3/' "$PLAN30_EMBEDDINGS_VALID" > "$C_EMB_DIMS/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_DIMS" 1 "does not match dims" \
    "validate-store.sh flags a dims/vector-length mismatch in embeddings.jsonl"

  C_EMB_NO_PERSON="$PLAN30_TMP_ROOT/case-embeddings-no-person"
  plan30_min_store "$C_EMB_NO_PERSON"
  mkdir -p "$C_EMB_NO_PERSON/index"
  sed 's/"slug": "sample-person"/"slug": "ghost-person"/' "$PLAN30_EMBEDDINGS_VALID" > "$C_EMB_NO_PERSON/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_NO_PERSON" 1 "does not resolve to people" \
    "validate-store.sh flags an embeddings.jsonl slug with no matching people file"

  C_EMB_MALFORMED="$PLAN30_TMP_ROOT/case-embeddings-malformed-json"
  plan30_min_store "$C_EMB_MALFORMED"
  mkdir -p "$C_EMB_MALFORMED/index"
  printf '{not valid json\n' > "$C_EMB_MALFORMED/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_MALFORMED" 1 "malformed JSON" \
    "validate-store.sh flags a malformed JSON line in embeddings.jsonl"

  C_EMB_NONUNIT="$PLAN30_TMP_ROOT/case-embeddings-nonunit-vector"
  plan30_min_store "$C_EMB_NONUNIT"
  cp "$C_EMB_VALID/people/sample-person.md" "$C_EMB_NONUNIT/people/sample-person.md"
  mkdir -p "$C_EMB_NONUNIT/index"
  sed 's/"vector": \[0.18257418583505536, -0.3651483716701107, 0.5477225575051661, 0.7302967433402214\]/"vector": [0.1, -0.2, 0.3, 0.4]/' \
    "$PLAN30_EMBEDDINGS_VALID" > "$C_EMB_NONUNIT/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_NONUNIT" 1 "not unit-normalized" \
    "validate-store.sh flags a non-unit-norm vector in embeddings.jsonl"

  C_EMB_ZERO="$PLAN30_TMP_ROOT/case-embeddings-zero-vector"
  plan30_min_store "$C_EMB_ZERO"
  cp "$C_EMB_VALID/people/sample-person.md" "$C_EMB_ZERO/people/sample-person.md"
  mkdir -p "$C_EMB_ZERO/index"
  sed 's/"vector": \[0.18257418583505536, -0.3651483716701107, 0.5477225575051661, 0.7302967433402214\]/"vector": [0, 0, 0, 0]/' \
    "$PLAN30_EMBEDDINGS_VALID" > "$C_EMB_ZERO/index/embeddings.jsonl"
  plan30_assert_finding "$C_EMB_ZERO" 0 "store clean" \
    "validate-store.sh accepts an all-zero vector (the norm exemption)"
fi

rm -rf "$PLAN30_TMP_ROOT"
trap - EXIT

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

STORE_TESTS_STATUS=0
if [ "$FAIL_COUNT" -ne 0 ]; then
  STORE_TESTS_STATUS=1
fi

# --- delegate to the build-stats.sh golden test, tallying its exit status
#     alongside this script's own ---
BUILD_STATS_TEST="$SCRIPT_DIR/test-build-stats.sh"
echo ""
echo "--- test-build-stats.sh ---"
if [ -x "$BUILD_STATS_TEST" ]; then
  "$BUILD_STATS_TEST"
  build_stats_status=$?
  if [ "$build_stats_status" -ne 0 ]; then
    STORE_TESTS_STATUS=1
  fi
else
  echo "FAIL: $BUILD_STATS_TEST not found or not executable"
  STORE_TESTS_STATUS=1
fi

# --- delegate to the wakeup-add.sh golden test, tallying its exit status
#     alongside this script's own ---
WAKEUP_ADD_TEST="$SCRIPT_DIR/test-wakeup-add.sh"
echo ""
echo "--- test-wakeup-add.sh ---"
if [ -x "$WAKEUP_ADD_TEST" ]; then
  "$WAKEUP_ADD_TEST"
  wakeup_add_status=$?
  if [ "$wakeup_add_status" -ne 0 ]; then
    STORE_TESTS_STATUS=1
  fi
else
  echo "FAIL: $WAKEUP_ADD_TEST not found or not executable"
  STORE_TESTS_STATUS=1
fi

# --- delegate to the demo-store.sh golden test, tallying its exit status
#     alongside this script's own ---
DEMO_STORE_TEST="$SCRIPT_DIR/test-demo-store.sh"
echo ""
echo "--- test-demo-store.sh ---"
if [ -x "$DEMO_STORE_TEST" ]; then
  "$DEMO_STORE_TEST"
  demo_store_status=$?
  if [ "$demo_store_status" -ne 0 ]; then
    STORE_TESTS_STATUS=1
  fi
else
  echo "FAIL: $DEMO_STORE_TEST not found or not executable"
  STORE_TESTS_STATUS=1
fi

# --- delegate to the init-store.sh / check-store-location.sh golden test,
#     tallying its exit status alongside this script's own ---
INIT_STORE_TEST="$SCRIPT_DIR/test-init-store.sh"
echo ""
echo "--- test-init-store.sh ---"
if [ -x "$INIT_STORE_TEST" ]; then
  "$INIT_STORE_TEST"
  init_store_status=$?
  if [ "$init_store_status" -ne 0 ]; then
    STORE_TESTS_STATUS=1
  fi
else
  echo "FAIL: $INIT_STORE_TEST not found or not executable"
  STORE_TESTS_STATUS=1
fi

exit "$STORE_TESTS_STATUS"
