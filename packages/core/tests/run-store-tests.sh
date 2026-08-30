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

# ---------------------------------------------------------------------------
# assertion 8: plan-31 tier-provenance write path (person-set-tier.sh) —
# round trip, both refusal shapes (derived-over-stated, --clear derived),
# --clear, and byte-identity of every non-tier* line.
# ---------------------------------------------------------------------------

PLAN31_TIER_SCRIPT="$REPO_ROOT/packages/core/scripts/person-set-tier.sh"
PLAN31_SOURCE_STORE="$REPO_ROOT/packages/core/fixtures/store"

echo ""
echo "--- plan 31: person-set-tier.sh round-trip + refusals ---"

TIER_STORE="$PLAN30_TMP_ROOT/tier-store"

if [ ! -x "$PLAN31_TIER_SCRIPT" ]; then
  fail "$PLAN31_TIER_SCRIPT not found or not executable"
elif [ ! -d "$PLAN31_SOURCE_STORE" ]; then
  fail "plan31 tier tests: source store fixture missing at $PLAN31_SOURCE_STORE"
else
  cp -R "$PLAN31_SOURCE_STORE" "$TIER_STORE"

  TIER_TARGET="$TIER_STORE/people/aiko-tanaka.md"
  if [ ! -f "$TIER_TARGET" ]; then
    fail "plan31 tier round-trip: fixture person people/aiko-tanaka.md missing"
  else
    tier_before_snapshot="$PLAN30_TMP_ROOT/aiko-tier-before.md"
    cp "$TIER_TARGET" "$tier_before_snapshot"

    tier_set_output="$("$PLAN31_TIER_SCRIPT" "$TIER_STORE" aiko-tanaka --tier close --source stated-by-user --today 2026-08-30 2>&1)"
    tier_set_status=$?

    if [ "$tier_set_status" -eq 0 ]; then
      pass "person-set-tier.sh exits 0 on a valid stated-by-user write"
    else
      fail "person-set-tier.sh exited $tier_set_status (expected 0) on a valid stated-by-user write: $tier_set_output"
    fi

    if printf '%s' "$tier_set_output" | grep -qF "set tier=close source=stated-by-user for aiko-tanaka"; then
      pass "person-set-tier.sh prints the expected confirmation line"
    else
      fail "person-set-tier.sh did not print the expected confirmation line, got: $tier_set_output"
    fi

    if grep -qxF "tier: close" "$TIER_TARGET" && grep -qxF "tier_source: stated-by-user" "$TIER_TARGET"; then
      pass "person-set-tier.sh wrote both tier fields with the expected values"
    else
      fail "person-set-tier.sh did not write the expected tier* field values"
      cat "$TIER_TARGET"
    fi

    tier_diff_out="$(diff <(grep -v '^tier' "$tier_before_snapshot") <(grep -v '^tier' "$TIER_TARGET"))"
    if [ -z "$tier_diff_out" ]; then
      pass "person-set-tier.sh leaves every non-tier* line byte-identical"
    else
      fail "person-set-tier.sh changed a non-tier* line"
      echo "$tier_diff_out"
    fi

    tier_derived_output="$("$PLAN31_TIER_SCRIPT" "$TIER_STORE" aiko-tanaka --tier active --source derived --today 2026-08-30 2>&1)"
    tier_derived_status=$?
    if [ "$tier_derived_status" -eq 2 ]; then
      pass "person-set-tier.sh exits 2 when a derived write targets a stated-by-user tier"
    else
      fail "person-set-tier.sh exited $tier_derived_status (expected 2) on derived-over-stated refusal"
    fi
    if printf '%s' "$tier_derived_output" | grep -qi "refusing"; then
      pass "person-set-tier.sh stderr mentions 'refusing' on derived-over-stated refusal"
    else
      fail "person-set-tier.sh did not mention 'refusing' in output: $tier_derived_output"
    fi
    if grep -qxF "tier: close" "$TIER_TARGET" && grep -qxF "tier_source: stated-by-user" "$TIER_TARGET"; then
      pass "person-set-tier.sh leaves the file untouched after a refused derived write"
    else
      fail "person-set-tier.sh mutated the file despite refusing the derived write"
    fi

    tier_clear_derived_output="$("$PLAN31_TIER_SCRIPT" "$TIER_STORE" aiko-tanaka --clear --source derived 2>&1)"
    tier_clear_derived_status=$?
    if [ "$tier_clear_derived_status" -eq 2 ]; then
      pass "person-set-tier.sh exits 2 for --clear --source derived"
    else
      fail "person-set-tier.sh exited $tier_clear_derived_status (expected 2) for --clear --source derived: $tier_clear_derived_output"
    fi

    tier_clear_output="$("$PLAN31_TIER_SCRIPT" "$TIER_STORE" aiko-tanaka --clear --source stated-by-user 2>&1)"
    tier_clear_status=$?
    if [ "$tier_clear_status" -eq 0 ] && ! grep -q '^tier:' "$TIER_TARGET" && ! grep -q '^tier_source:' "$TIER_TARGET"; then
      pass "person-set-tier.sh --clear removes both tier and tier_source"
    else
      fail "person-set-tier.sh --clear (exit $tier_clear_status) did not remove tier/tier_source as expected"
      cat "$TIER_TARGET"
    fi
  fi

  # --- derived write into a person with no existing tier line (insert path) ---
  TIER_TARGET2="$TIER_STORE/people/ayesha-malik.md"
  if [ ! -f "$TIER_TARGET2" ]; then
    fail "plan31 tier tests: fixture person people/ayesha-malik.md missing"
  else
    "$PLAN31_TIER_SCRIPT" "$TIER_STORE" ayesha-malik --clear --source stated-by-user > /dev/null 2>&1
    tier_insert_output="$("$PLAN31_TIER_SCRIPT" "$TIER_STORE" ayesha-malik --tier dormant --source derived --today 2026-08-30 2>&1)"
    tier_insert_status=$?
    if [ "$tier_insert_status" -eq 0 ] && grep -qxF "tier: dormant" "$TIER_TARGET2" && grep -qxF "tier_source: derived" "$TIER_TARGET2"; then
      pass "person-set-tier.sh inserts tier/tier_source on a person with no prior tier line"
    else
      fail "person-set-tier.sh (exit $tier_insert_status) did not insert tier/tier_source as expected"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# assertion 8b: plan-34 feedback-ledger hook — person-set-tier.sh /
# person-set-kind.sh only append to signals/feedback.jsonl on a stated-by-user
# write (mission test: only stated corrections are recorded). Uses the same
# person-set-tier.sh / person-set-kind.sh scripts as assertion 8, plus
# packages/ingestion/scripts/feedback-file.sh.
# ---------------------------------------------------------------------------

echo ""
echo "--- plan 34: feedback-ledger hook (person-set-tier.sh / person-set-kind.sh) ---"

PLAN34_KIND_SCRIPT="$REPO_ROOT/packages/core/scripts/person-set-kind.sh"
PLAN34_FEEDBACK_FILE_SCRIPT="$REPO_ROOT/packages/ingestion/scripts/feedback-file.sh"

if [ ! -x "$PLAN31_TIER_SCRIPT" ]; then
  fail "$PLAN31_TIER_SCRIPT not found or not executable (plan 34 feedback tests)"
elif [ ! -x "$PLAN34_KIND_SCRIPT" ]; then
  fail "$PLAN34_KIND_SCRIPT not found or not executable (plan 34 feedback tests)"
elif [ ! -x "$PLAN34_FEEDBACK_FILE_SCRIPT" ]; then
  fail "$PLAN34_FEEDBACK_FILE_SCRIPT not found or not executable (plan 34 feedback tests)"
elif ! command -v jq >/dev/null 2>&1; then
  fail "jq not found on PATH — cannot check plan-34 feedback-ledger contents"
else
  FEEDBACK_STORE="$PLAN30_TMP_ROOT/feedback-store"
  plan30_min_store "$FEEDBACK_STORE"
  FEEDBACK_LEDGER="$FEEDBACK_STORE/signals/feedback.jsonl"

  # --- case 1: stated tier write with feedback text -> one ledger line ---
  cat > "$FEEDBACK_STORE/people/feedback-person.md" <<'EOF'
---
schema_version: 1.2.0
name: Feedback Person
tier: active
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF

  fb1_output="$("$PLAN31_TIER_SCRIPT" "$FEEDBACK_STORE" feedback-person --tier close --source stated-by-user --today 2026-08-30 --feedback-text "she's basically family" 2>&1)"
  fb1_status=$?

  if [ "$fb1_status" -eq 0 ] && [ -f "$FEEDBACK_LEDGER" ] && [ "$(wc -l < "$FEEDBACK_LEDGER" | tr -d ' ')" -eq 1 ]; then
    pass "stated-by-user tier write appends exactly one feedback-ledger line"
  else
    fail "stated-by-user tier write did not append exactly one feedback-ledger line (exit $fb1_status): $fb1_output"
  fi

  if [ -f "$FEEDBACK_LEDGER" ]; then
    fb1_line="$(tail -n1 "$FEEDBACK_LEDGER")"
    fb1_type="$(printf '%s' "$fb1_line" | jq -r '.type')"
    fb1_target="$(printf '%s' "$fb1_line" | jq -r '.target')"
    fb1_from="$(printf '%s' "$fb1_line" | jq -r '.from')"
    fb1_to="$(printf '%s' "$fb1_line" | jq -r '.to')"
    fb1_text="$(printf '%s' "$fb1_line" | jq -r '.text')"
    fb1_source="$(printf '%s' "$fb1_line" | jq -r '.source')"

    if [ "$fb1_type" = "tier-correction" ] && [ "$fb1_target" = "person:feedback-person" ] && \
       [ "$fb1_from" = "active" ] && [ "$fb1_to" = "close" ] && \
       [ "$fb1_text" = "she's basically family" ] && [ "$fb1_source" = "session" ]; then
      pass "feedback-ledger tier-correction line has the expected type/target/from/to/text/source"
    else
      fail "feedback-ledger tier-correction line did not match expected fields: $fb1_line"
    fi
  fi

  # --- case 2: derived write -> no new ledger line ---
  fb2_lines_before="$(wc -l < "$FEEDBACK_LEDGER" | tr -d ' ')"
  fb2_output="$("$PLAN31_TIER_SCRIPT" "$FEEDBACK_STORE" feedback-person --tier active --source derived --today 2026-08-30 --feedback-text "should be ignored" 2>&1)"
  fb2_status=$?
  fb2_lines_after="$(wc -l < "$FEEDBACK_LEDGER" | tr -d ' ')"

  if [ "$fb2_status" -eq 2 ] && [ "$fb2_lines_before" -eq "$fb2_lines_after" ]; then
    pass "derived write does not append to signals/feedback.jsonl (refused as expected: existing tier is stated-by-user)"
  else
    fail "derived write behaved unexpectedly (exit $fb2_status, ledger lines $fb2_lines_before -> $fb2_lines_after): $fb2_output"
  fi

  # --- case 3: kind stated write on a person with no prior kind -> from=null ---
  fb3_lines_before="$(wc -l < "$FEEDBACK_LEDGER" | tr -d ' ')"
  fb3_output="$("$PLAN34_KIND_SCRIPT" "$FEEDBACK_STORE" feedback-person --kind friend --note "college friend" --source stated-by-user --today 2026-08-30 --feedback-text "he's a close friend" 2>&1)"
  fb3_status=$?
  fb3_lines_after="$(wc -l < "$FEEDBACK_LEDGER" | tr -d ' ')"

  if [ "$fb3_status" -eq 0 ] && [ "$fb3_lines_after" -eq $((fb3_lines_before + 1)) ]; then
    pass "stated-by-user kind write appends exactly one feedback-ledger line"
  else
    fail "stated-by-user kind write (exit $fb3_status) did not append exactly one feedback-ledger line ($fb3_lines_before -> $fb3_lines_after): $fb3_output"
  fi

  fb3_line="$(tail -n1 "$FEEDBACK_LEDGER")"
  fb3_type="$(printf '%s' "$fb3_line" | jq -r '.type')"
  fb3_from="$(printf '%s' "$fb3_line" | jq -r '.from')"
  fb3_to="$(printf '%s' "$fb3_line" | jq -r '.to')"

  if [ "$fb3_type" = "kind-correction" ] && [ "$fb3_from" = "null" ] && [ "$fb3_to" = "friend" ]; then
    pass "feedback-ledger kind-correction line reads from=null for a person with no prior kind"
  else
    fail "feedback-ledger kind-correction line did not read from=null/to=friend: $fb3_line"
  fi

  # --- case 4: --clear --source stated-by-user -> to="null" (the string) ---
  fb4_output="$("$PLAN31_TIER_SCRIPT" "$FEEDBACK_STORE" feedback-person --clear --source stated-by-user 2>&1)"
  fb4_status=$?
  fb4_line="$(tail -n1 "$FEEDBACK_LEDGER")"
  fb4_to="$(printf '%s' "$fb4_line" | jq -r '.to')"

  if [ "$fb4_status" -eq 0 ] && [ "$fb4_to" = "null" ]; then
    pass "person-set-tier.sh --clear --source stated-by-user appends a feedback-ledger line with to=\"null\""
  else
    fail "person-set-tier.sh --clear (exit $fb4_status) did not append to=\"null\" ledger line: $fb4_line"
  fi

  # --- case 5: feedback-file.sh absent -> skip message, exit 0, person still updated ---
  FEEDBACK_ABSENT_ROOT="$PLAN30_TMP_ROOT/feedback-absent"
  mkdir -p "$FEEDBACK_ABSENT_ROOT/core/scripts"
  cp "$PLAN31_TIER_SCRIPT" "$FEEDBACK_ABSENT_ROOT/core/scripts/person-set-tier.sh"
  cp "$PLAN34_KIND_SCRIPT" "$FEEDBACK_ABSENT_ROOT/core/scripts/person-set-kind.sh"
  chmod +x "$FEEDBACK_ABSENT_ROOT/core/scripts/person-set-tier.sh" "$FEEDBACK_ABSENT_ROOT/core/scripts/person-set-kind.sh"

  FEEDBACK_ABSENT_STORE="$PLAN30_TMP_ROOT/feedback-absent-store"
  plan30_min_store "$FEEDBACK_ABSENT_STORE"
  cat > "$FEEDBACK_ABSENT_STORE/people/absent-person.md" <<'EOF'
---
schema_version: 1.2.0
name: Absent Person
tier: active
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF

  fb5_output="$("$FEEDBACK_ABSENT_ROOT/core/scripts/person-set-tier.sh" "$FEEDBACK_ABSENT_STORE" absent-person --tier close --source stated-by-user --today 2026-08-30 --feedback-text "she's basically family" 2>&1)"
  fb5_status=$?

  if [ "$fb5_status" -eq 0 ] && printf '%s' "$fb5_output" | grep -qF "feedback: skipped (feedback-file.sh absent)"; then
    pass "person-set-tier.sh exits 0 and prints the skip message when feedback-file.sh is absent"
  else
    fail "person-set-tier.sh (exit $fb5_status) did not print the expected skip message: $fb5_output"
  fi

  if [ ! -d "$FEEDBACK_ABSENT_STORE/signals" ] && grep -qxF "tier: close" "$FEEDBACK_ABSENT_STORE/people/absent-person.md"; then
    pass "person-set-tier.sh with feedback-file.sh absent still updates the person file, and writes no signals/ dir"
  else
    fail "person-set-tier.sh with feedback-file.sh absent left an unexpected store state"
    cat "$FEEDBACK_ABSENT_STORE/people/absent-person.md"
  fi
fi

# ---------------------------------------------------------------------------
# assertion 9: plan-31 validate-store.sh rules — person tier_source, and
# user-model.md status: provisional.
# ---------------------------------------------------------------------------

echo ""
echo "--- plan 31: validate-store.sh tier_source / provisional rules ---"

C_TIER_SOURCE_ORPHAN="$PLAN30_TMP_ROOT/case-tier-source-orphan"
plan30_min_store "$C_TIER_SOURCE_ORPHAN"
cat > "$C_TIER_SOURCE_ORPHAN/people/test-person.md" <<'EOF'
---
schema_version: 1.2.0
name: Test Person
tier_source: derived
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_TIER_SOURCE_ORPHAN" 1 "tier_source is set without tier" \
  "validate-store.sh flags tier_source present without tier"

C_TIER_SOURCE_BAD="$PLAN30_TMP_ROOT/case-tier-source-bad-vocab"
plan30_min_store "$C_TIER_SOURCE_BAD"
cat > "$C_TIER_SOURCE_BAD/people/test-person.md" <<'EOF'
---
schema_version: 1.2.0
name: Test Person
tier: close
tier_source: bogus-source
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_TIER_SOURCE_BAD" 1 "invalid tier_source" \
  "validate-store.sh flags a tier_source value outside derived|stated-by-user"

C_TIER_SOURCE_OK="$PLAN30_TMP_ROOT/case-tier-source-ok"
plan30_min_store "$C_TIER_SOURCE_OK"
cat > "$C_TIER_SOURCE_OK/people/test-person.md" <<'EOF'
---
schema_version: 1.2.0
name: Test Person
tier: close
tier_source: derived
---

## Facts

- **[told-by-user]** placeholder fact (2026-08-01)
EOF
plan30_assert_finding "$C_TIER_SOURCE_OK" 0 "store clean" \
  "validate-store.sh accepts a valid tier/tier_source pair"

if [ ! -f "$PLAN30_USER_MODEL_VALID" ]; then
  fail "plan31 provisional tests: fixture missing at $PLAN30_USER_MODEL_VALID"
else
  C_UM_PROVISIONAL="$PLAN30_TMP_ROOT/case-user-model-provisional"
  plan30_min_store "$C_UM_PROVISIONAL"
  sed -e 's/^status: confirmed$/status: provisional/' \
      -e 's/^confirmed_at: 2026-08-25$/confirmed_at: null/' \
      -e 's/^revision: 1$/revision: 0/' \
      -e 's/^provenance: stated-by-user$/provenance: observed-from-behavior/' \
    "$PLAN30_USER_MODEL_VALID" > "$C_UM_PROVISIONAL/user-model.md"
  plan30_assert_finding "$C_UM_PROVISIONAL" 0 "store clean" \
    "validate-store.sh accepts a valid status: provisional user-model.md"

  C_UM_PROVISIONAL_MISMATCH="$PLAN30_TMP_ROOT/case-user-model-provisional-mismatch"
  plan30_min_store "$C_UM_PROVISIONAL_MISMATCH"
  sed -e 's/^status: confirmed$/status: provisional/' \
    "$PLAN30_USER_MODEL_VALID" > "$C_UM_PROVISIONAL_MISMATCH/user-model.md"
  plan30_assert_finding "$C_UM_PROVISIONAL_MISMATCH" 1 "requires provenance: observed-from-behavior" \
    "validate-store.sh flags status: provisional paired with provenance: stated-by-user"
fi

rm -rf "$PLAN30_TMP_ROOT"
trap - EXIT

# ---------------------------------------------------------------------------
# eval private manifest mode (plan 34 D4) — RA_EVAL_PRIVATE_MANIFEST opts
# exactly ONE manifest (matched by exact resolved path) into allowing its
# case store/expected paths to resolve under data/; every other manifest —
# even another one also under data/ — keeps the refusal. Builds a synthetic
# private-style suite + skill-tier case under a scratch dir (never touches
# the real data/ dir) and drives packages/core/scripts/eval-suite.sh under
# RA_EVAL_DRY_RUN=1 so no `claude -p` calls are ever made.
# ---------------------------------------------------------------------------

echo ""
echo "--- eval private manifest mode ---"

EVAL_SUITE_SCRIPT="$REPO_ROOT/packages/core/scripts/eval-suite.sh"
EVAL_TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$EVAL_TMP_ROOT"' EXIT

if [ ! -x "$EVAL_SUITE_SCRIPT" ]; then
  fail "$EVAL_SUITE_SCRIPT not found or not executable"
else
  # Manifest A (opted in by RA_EVAL_PRIVATE_MANIFEST in cases 2 and 3 below)
  # — a minimal skill-tier case shaped like
  # packages/ingestion/evals/cases/01-tier-change (prompt.md + store/expected
  # dirs), but with its store/expected under the same data/ dir as the
  # manifest itself.
  FEEDBACK_DIR="$EVAL_TMP_ROOT/data/evals/feedback"
  CASE_A_DIR="$FEEDBACK_DIR/case-a"
  mkdir -p "$CASE_A_DIR/before" "$CASE_A_DIR/expected"
  cat > "$CASE_A_DIR/prompt.md" <<EOF
---
tier: skill
store: $CASE_A_DIR/before
expected: $CASE_A_DIR/expected
max-turns: 8
model: haiku
---
Test-only prompt body (never dispatched — RA_EVAL_DRY_RUN=1 in every
assertion below).
EOF
  FEEDBACK_SUITE="$FEEDBACK_DIR/suite.txt"
  printf '%s\n' "$CASE_A_DIR" > "$FEEDBACK_SUITE"

  # Manifest B — a second, unrelated manifest also under data/, never opted
  # in by RA_EVAL_PRIVATE_MANIFEST in any assertion below.
  OTHER_DIR="$EVAL_TMP_ROOT/data/evals/other"
  CASE_B_DIR="$OTHER_DIR/case-b"
  mkdir -p "$CASE_B_DIR/before" "$CASE_B_DIR/expected"
  cat > "$CASE_B_DIR/prompt.md" <<EOF
---
tier: skill
store: $CASE_B_DIR/before
expected: $CASE_B_DIR/expected
max-turns: 8
model: haiku
---
Test-only prompt body (never dispatched — RA_EVAL_DRY_RUN=1 in every
assertion below).
EOF
  OTHER_SUITE="$OTHER_DIR/suite.txt"
  printf '%s\n' "$CASE_B_DIR" > "$OTHER_SUITE"

  # --- case 1: committed-style run (env unset) refuses a data/-path case ---
  case1_out="$(RA_EVAL_DRY_RUN=1 "$EVAL_SUITE_SCRIPT" "$FEEDBACK_SUITE" 2>&1)"
  if printf '%s\n' "$case1_out" | grep -qF "RESULT ERROR case=case-a reason=refused-data-path:store="; then
    pass "eval-suite.sh refuses a data/-path case when RA_EVAL_PRIVATE_MANIFEST is unset"
  else
    fail "eval-suite.sh did not refuse the data/-path case with RA_EVAL_PRIVATE_MANIFEST unset"
    echo "$case1_out"
  fi

  # --- case 2: same suite, RA_EVAL_PRIVATE_MANIFEST set to it -> allowed ---
  # eval-suite.sh prints the physical (symlink-resolved, `pwd -P`) form of
  # the manifest dir, which on macOS differs from $EVAL_TMP_ROOT's own
  # /tmp/... spelling (a symlink to /private/tmp/...) — resolve the same
  # way here so the expected-line check isn't a false negative.
  FEEDBACK_DIR_PHYSICAL="$(cd "$FEEDBACK_DIR" && pwd -P)"
  case2_out="$(RA_EVAL_DRY_RUN=1 RA_EVAL_PRIVATE_MANIFEST="$FEEDBACK_SUITE" "$EVAL_SUITE_SCRIPT" "$FEEDBACK_SUITE" 2>&1)"
  if printf '%s\n' "$case2_out" | grep -qF "eval: private manifest mode (${FEEDBACK_DIR_PHYSICAL})"; then
    pass "eval-suite.sh prints the private manifest mode line for the opted-in manifest"
  else
    fail "eval-suite.sh did not print the private manifest mode line"
    echo "$case2_out"
  fi
  if printf '%s\n' "$case2_out" | grep -qF "RESULT SKIP case=case-a reason=dry-run"; then
    pass "eval-suite.sh's opted-in manifest case proceeds past the data/ refusal (dry-run SKIP, not ERROR)"
  else
    fail "eval-suite.sh's opted-in manifest case did not proceed to dry-run SKIP"
    echo "$case2_out"
  fi

  # --- case 3: RA_EVAL_PRIVATE_MANIFEST set to manifest A, but manifest B
  #     (also under data/, a different directory) is still refused ---
  case3_out="$(RA_EVAL_DRY_RUN=1 RA_EVAL_PRIVATE_MANIFEST="$FEEDBACK_SUITE" "$EVAL_SUITE_SCRIPT" "$OTHER_SUITE" 2>&1)"
  if printf '%s\n' "$case3_out" | grep -qF "RESULT ERROR case=case-b reason=refused-data-path:store="; then
    pass "eval-suite.sh still refuses a different data/ manifest's case even when another manifest is opted in"
  else
    fail "eval-suite.sh did not refuse manifest B's case despite manifest A being the opted-in one"
    echo "$case3_out"
  fi
  if printf '%s\n' "$case3_out" | grep -qF "eval: private manifest mode"; then
    fail "eval-suite.sh printed the private manifest mode line for a run that never included the opted-in manifest"
  else
    pass "eval-suite.sh prints no private manifest mode line when the opted-in manifest isn't the one run"
  fi
fi

rm -rf "$EVAL_TMP_ROOT"
trap - EXIT

# --- case 4: real repo suite unaffected — RA_EVAL_DRY_RUN=1 still exits 0
#     with error=0 (regression guard: private-manifest mode changes nothing
#     for manifests that never resolve under data/) ---
INGESTION_SUITE_REL="packages/ingestion/evals/suite.txt"
if [ ! -f "$REPO_ROOT/$INGESTION_SUITE_REL" ]; then
  fail "$INGESTION_SUITE_REL not found — cannot run case 4"
else
  case4_out="$(cd "$REPO_ROOT" && RA_EVAL_DRY_RUN=1 bash packages/core/scripts/eval-suite.sh "$INGESTION_SUITE_REL" 2>&1)"
  case4_status=$?
  if [ "$case4_status" -eq 0 ]; then
    pass "RA_EVAL_DRY_RUN=1 eval-suite.sh $INGESTION_SUITE_REL exits 0"
  else
    fail "RA_EVAL_DRY_RUN=1 eval-suite.sh $INGESTION_SUITE_REL exited $case4_status (expected 0)"
    echo "$case4_out"
  fi
  if printf '%s\n' "$case4_out" | grep -qE "SUITE SUMMARY:.*error=0"; then
    pass "RA_EVAL_DRY_RUN=1 eval-suite.sh $INGESTION_SUITE_REL reports error=0"
  else
    fail "RA_EVAL_DRY_RUN=1 eval-suite.sh $INGESTION_SUITE_REL did not report error=0"
    echo "$case4_out"
  fi
fi

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
