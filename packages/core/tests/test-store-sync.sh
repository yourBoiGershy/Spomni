#!/usr/bin/env bash
# packages/core/tests/test-store-sync.sh
#
# Covers packages/core/scripts/store-sync.sh:
#   1. status on a git store prints "store=" ... "git=yes".
#   2. commit -m "first" succeeds, creates index.json/stats.json, and
#      commits with the fallback identity (Spomni / spomni@localhost, or
#      SPOMNI_GIT_NAME/SPOMNI_GIT_EMAIL when set) when no user.name is
#      configured.
#   3. commit again with nothing changed is a no-op ("nothing to commit").
#   4. a store with a corrupted person.md (missing schema_version:) refuses
#      to commit ("FAIL: store-sync commit refused"), stages nothing.
#   5. a non-git store dir is a no-op for commit ("not a git repo"); status
#      reports "git=no".
#   6. push race: two clones of a bare remote, non-conflicting changes to
#      different files retry-and-succeed; a real same-line conflict fails
#      twice ("FAIL:").
#   7. store-sync.sh refuses (exit 2, "FAIL:") when the store dir is the
#      code checkout itself.
#
# bash 3.2 portable (no associative arrays, no mapfile). Never asserts on
# rebase — store-sync.sh promises it never rebases.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STORE_SYNC="$REPO_ROOT/packages/core/scripts/store-sync.sh"
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

SCRATCH_DIRS=""

cleanup() {
  for d in $SCRATCH_DIRS; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

new_scratch_dir() {
  local dir
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'store-sync-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  printf '%s\n' "$dir"
}

if [ ! -x "$STORE_SYNC" ]; then
  echo "SKIP: $STORE_SYNC not found or not executable — cannot run store-sync tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, store-sync.sh missing"
  exit 1
fi

if [ ! -d "$FIXTURE_STORE" ]; then
  echo "SKIP: $FIXTURE_STORE not found — cannot run store-sync tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, fixture store missing"
  exit 1
fi

# Isolated HOME + no global git config, so the identity-fallback case really
# has no user.name/user.email to fall back on.
TEST_HOME="$(new_scratch_dir)"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# init_git_store <dir> — copy the fixture store into <dir> and make it a git
# repo with one setup commit (explicit -c identity, never relied on for the
# store-sync calls under test).
init_git_store() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$FIXTURE_STORE/." "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=setup -c user.email=setup@example.com add -A
  git -C "$dir" -c user.name=setup -c user.email=setup@example.com commit -q -m "setup: seed fixture store"
}

# ---------------------------------------------------------------------------
# assertion 1: status on a git store
# ---------------------------------------------------------------------------

scratch1="$(new_scratch_dir)"
store1="$scratch1/store"
init_git_store "$store1"

status_output1="$("$STORE_SYNC" "$store1" status 2>&1)"
status_exit1=$?

if [ "$status_exit1" -eq 0 ] \
  && printf '%s' "$status_output1" | grep -qE '^store='  \
  && printf '%s' "$status_output1" | grep -qF "git=yes"
then
  pass "status on a git store prints store=... git=yes"
else
  fail "status on a git store did not print the expected line (exit=$status_exit1)"
  echo "$status_output1"
fi

# ---------------------------------------------------------------------------
# assertion 2: commit succeeds, reindexes, and uses fallback identity
# ---------------------------------------------------------------------------

scratch2="$(new_scratch_dir)"
store2="$scratch2/store"
init_git_store "$store2"

commit_output2="$(unset SPOMNI_GIT_NAME SPOMNI_GIT_EMAIL; "$STORE_SYNC" "$store2" commit -m "first" 2>&1)"
commit_exit2=$?

if [ "$commit_exit2" -eq 0 ] && printf '%s' "$commit_output2" | grep -qF "store-sync: committed"; then
  pass "commit -m first exits 0 and prints store-sync: committed"
else
  fail "commit -m first did not succeed as expected (exit=$commit_exit2)"
  echo "$commit_output2"
fi

if [ -f "$store2/index.json" ] && [ -f "$store2/stats.json" ]; then
  pass "commit reindexed: index.json and stats.json exist"
else
  fail "commit did not create index.json/stats.json"
fi

author2="$(git -C "$store2" log -1 --format=%an)"
if [ "$author2" = "Spomni" ]; then
  pass "commit falls back to the default identity (Spomni) when no user.name is configured"
else
  fail "commit did not fall back to the default identity (got author=$author2)"
fi

scratch2b="$(new_scratch_dir)"
store2b="$scratch2b/store"
init_git_store "$store2b"

commit_output2b="$(SPOMNI_GIT_NAME=Phone SPOMNI_GIT_EMAIL=p@example.com "$STORE_SYNC" "$store2b" commit -m "first" 2>&1)"
commit_exit2b=$?
author2b="$(git -C "$store2b" log -1 --format=%an)"

if [ "$commit_exit2b" -eq 0 ] && [ "$author2b" = "Phone" ]; then
  pass "SPOMNI_GIT_NAME/SPOMNI_GIT_EMAIL override the fallback identity"
else
  fail "SPOMNI_GIT_NAME override did not take effect (exit=$commit_exit2b, author=$author2b)"
  echo "$commit_output2b"
fi

# ---------------------------------------------------------------------------
# assertion 3: commit again with nothing changed is a no-op
#
# build-stats.sh stamps a fresh `generated_at` into stats.json on every
# reindex, so two real commit calls in a row would otherwise never see a
# byte-for-byte identical stats.json. store-sync.sh's commit path detects
# a staged diff limited to index.json/stats.json's generated_at line,
# reverts it, and reports nothing-to-commit — so this exercises the real
# path with no shims.
# ---------------------------------------------------------------------------

scratch3="$(new_scratch_dir)"
store3="$scratch3/store"
init_git_store "$store3"

commit_output3a="$("$STORE_SYNC" "$store3" commit -m "first" 2>&1)"
commit_output3="$("$STORE_SYNC" "$store3" commit -m "second" 2>&1)"
commit_exit3=$?

if [ "$commit_exit3" -eq 0 ] && printf '%s' "$commit_output3" | grep -qF "nothing to commit"; then
  pass "commit with nothing changed is a no-op (nothing to commit)"
else
  fail "unchanged commit did not report nothing to commit (exit=$commit_exit3)"
  echo "$commit_output3a"
  echo "$commit_output3"
fi

# ---------------------------------------------------------------------------
# assertion 4: corrupted store refuses to commit
# ---------------------------------------------------------------------------

scratch4="$(new_scratch_dir)"
store4="$scratch4/store"
init_git_store "$store4"

corrupt_person4="$(ls "$store4/people"/*.md | head -1)"
# Strip the schema_version: line to trigger a validate-store.sh failure.
sed -i.bak '/^schema_version:/d' "$corrupt_person4"
rm -f "${corrupt_person4}.bak"

commit_output4="$("$STORE_SYNC" "$store4" commit -m "corrupt" 2>&1)"
commit_exit4=$?
staged4="$(git -C "$store4" diff --cached --name-only)"

if [ "$commit_exit4" -eq 1 ] \
  && printf '%s' "$commit_output4" | grep -qF "FAIL: store-sync commit refused" \
  && [ -z "$staged4" ]
then
  pass "commit refuses (exit 1, FAIL:) and stages nothing when validate-store.sh fails"
else
  fail "corrupted commit did not refuse as expected (exit=$commit_exit4, staged='$staged4')"
  echo "$commit_output4"
fi

# ---------------------------------------------------------------------------
# assertion 5: non-git store dir is a no-op; status reports git=no
# ---------------------------------------------------------------------------

scratch5="$(new_scratch_dir)"
store5="$scratch5/store"
mkdir -p "$store5"
cp -R "$FIXTURE_STORE/." "$store5"

commit_output5="$("$STORE_SYNC" "$store5" commit -m "n/a" 2>&1)"
commit_exit5=$?

if [ "$commit_exit5" -eq 0 ] && printf '%s' "$commit_output5" | grep -qF "not a git repo"; then
  pass "commit on a non-git store dir is a no-op (not a git repo)"
else
  fail "commit on a non-git store dir did not no-op as expected (exit=$commit_exit5)"
  echo "$commit_output5"
fi

status_output5="$("$STORE_SYNC" "$store5" status 2>&1)"
if printf '%s' "$status_output5" | grep -qF "git=no"; then
  pass "status on a non-git store dir reports git=no"
else
  fail "status on a non-git store dir did not report git=no"
  echo "$status_output5"
fi

# ---------------------------------------------------------------------------
# assertion 6: push race — retry-and-succeed on non-conflicting changes,
# fail twice on a real conflict
# ---------------------------------------------------------------------------

scratch6="$(new_scratch_dir)"
remote6="$scratch6/remote.git"
git init -q --bare "$remote6"

# Seed the bare remote from a throwaway clone.
seed6="$scratch6/seed"
init_git_store "$seed6"
git -C "$seed6" remote add origin "$remote6"
git -C "$seed6" -c user.name=setup -c user.email=setup@example.com push -q origin HEAD:refs/heads/main
git -C "$remote6" symbolic-ref HEAD refs/heads/main

a6="$scratch6/a"
b6="$scratch6/b"
git clone -q "$remote6" "$a6"
git clone -q "$remote6" "$b6"
git -C "$a6" checkout -q -B main origin/main 2>/dev/null || true
git -C "$b6" checkout -q -B main origin/main 2>/dev/null || true

# B commits+pushes a new file.
echo "from B" > "$b6/notes.txt"
git -C "$b6" add notes.txt
git -C "$b6" -c user.name=b -c user.email=b@example.com commit -q -m "B: add notes.txt"
git -C "$b6" -c user.name=b -c user.email=b@example.com push -q origin HEAD:main

# A makes a store change that keeps validate-store.sh green.
a6_person="$(ls "$a6/people"/*.md | head -1)"
awk '/^## Facts$/{print; print "- **[told-by-user]** test fact"; next} {print}' "$a6_person" > "$a6_person.new"
mv "$a6_person.new" "$a6_person"

validate_check6="$("$REPO_ROOT/packages/core/scripts/validate-store.sh" "$a6" 2>&1)"
validate_status6=$?
if [ "$validate_status6" -ne 0 ]; then
  fail "assertion 6 setup: A's store change failed validate-store.sh before store-sync was even exercised"
  echo "$validate_check6"
fi

commit_output6a="$("$STORE_SYNC" "$a6" commit -m "A: add a fact" 2>&1)"
commit_exit6a=$?

push_output6a="$("$STORE_SYNC" "$a6" push 2>&1)"
push_exit6a=$?

remote_log6="$(git -C "$a6" log --oneline origin/main 2>/dev/null)"
if [ "$commit_exit6a" -eq 0 ] && [ "$push_exit6a" -eq 0 ] \
  && printf '%s' "$remote_log6" | grep -qF "B: add notes.txt" \
  && printf '%s' "$remote_log6" | grep -qF "A: add a fact"
then
  pass "push retries once via pull on rejection and lands both commits on the remote"
else
  fail "push race (non-conflicting) did not land both commits (commit_exit=$commit_exit6a, push_exit=$push_exit6a)"
  echo "$commit_output6a"
  echo "$push_output6a"
fi

# Real conflict: A and B both modify the same line of notes.txt; B pushes
# first. B must be caught up with the merge A just pushed, or B's own push
# would be the one that gets rejected instead of setting up the conflict.
git -C "$b6" -c user.name=b -c user.email=b@example.com pull -q --no-edit origin main

echo "B's edit" > "$b6/notes.txt"
git -C "$b6" add notes.txt
git -C "$b6" -c user.name=b -c user.email=b@example.com commit -q -m "B: edit notes.txt"
git -C "$b6" -c user.name=b -c user.email=b@example.com push -q origin HEAD:main

echo "A's edit" > "$a6/notes.txt"
git -C "$a6" add notes.txt
git -C "$a6" -c user.name=a -c user.email=a@example.com commit -q -m "A: edit notes.txt"

push_output6b="$("$STORE_SYNC" "$a6" push 2>&1)"
push_exit6b=$?

conflict_state6="$(git -C "$a6" status --porcelain 2>&1)"
if [ "$push_exit6b" -eq 1 ] && printf '%s' "$push_output6b" | grep -qF "FAIL:"; then
  pass "push fails (exit 1, FAIL:) on a real conflict"
else
  fail "push on a real conflict did not fail as expected (exit=$push_exit6b)"
  echo "$push_output6b"
fi

if printf '%s' "$push_output6b" | grep -qF "merge conflict" \
  || printf '%s' "$conflict_state6" | grep -qE '^(UU|AA) '
then
  pass "push on a real conflict leaves A in a visible conflict state"
else
  fail "push on a real conflict left no visible conflict trace"
  echo "$conflict_state6"
fi

# ---------------------------------------------------------------------------
# assertion 7: refuses on the code checkout itself
# ---------------------------------------------------------------------------

self_output7="$("$STORE_SYNC" "$REPO_ROOT" status 2>&1)"
self_exit7=$?

if [ "$self_exit7" -eq 2 ] && printf '%s' "$self_output7" | grep -qF "FAIL:"; then
  pass "store-sync.sh refuses (exit 2, FAIL:) when store-dir is the code checkout itself"
else
  fail "store-sync.sh did not refuse the code checkout as a store dir (exit=$self_exit7)"
  echo "$self_output7"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
