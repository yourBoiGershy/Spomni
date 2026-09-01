#!/usr/bin/env bash
# packages/core/tests/test-store-land.sh
#
# Covers packages/core/scripts/store-land.sh and the pre-commit validation
# hook (templates/store-pre-commit-hook.sh, installed by init-store.sh /
# store-sync.sh tick):
#   1. store-land on a non-git store dir refuses (exit 2, FAIL:).
#   2. store-land on the default branch delegates to store-sync tick.
#   3. branch-merge happy path — work branch validated, committed, merged
#      --no-ff into main, pushed; summary line
#      "store-land: landed <branch> -> main pushed=yes"; remote main has the
#      change; store ends on main.
#   4. merge conflict — abort, return to the work branch, print
#      "FAIL: merge conflict — resolve by hand", exit 1, no merge in
#      progress.
#   5. invalid store on a work branch — exit 1, nothing merged.
#   6. init-store.sh installs the pre-commit hook into a git store
#      (marker line present, executable), idempotently (no dup, and a
#      foreign hook is left alone with a SKIP line).
#   7. the installed hook blocks a commit of an invalid hand-written store
#      file (validator output surfaced) and allows a valid commit, with
#      SPOMNI_MACHINERY pointing at this checkout.
#   8. with no machinery discoverable the hook warns but ALLOWS the commit.
#   9. base-machine layout (store at <machinery>/data/store, no
#      SPOMNI_MACHINERY, no ./machinery) — the hook discovers the machinery
#      by walking up to the grandparent and validates (blocks invalid,
#      allows valid).
#
# bash 3.2 portable (no associative arrays, no mapfile). Self-contained
# temp dirs; local bare git remotes (same pattern as test-store-sync.sh).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STORE_LAND="$REPO_ROOT/packages/core/scripts/store-land.sh"
STORE_SYNC="$REPO_ROOT/packages/core/scripts/store-sync.sh"
INIT_STORE="$REPO_ROOT/packages/core/scripts/init-store.sh"
FIXTURE_STORE="$REPO_ROOT/packages/core/fixtures/store"
HOOK_MARKER="# spomni-store-validate-hook v1"

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
  dir="$(mktemp -d 2>/dev/null || mktemp -d -t 'store-land-test')"
  SCRATCH_DIRS="$SCRATCH_DIRS $dir"
  printf '%s\n' "$dir"
}

if [ ! -x "$STORE_LAND" ]; then
  echo "SKIP: $STORE_LAND not found or not executable — cannot run store-land tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, store-land.sh missing"
  exit 1
fi

# Isolated HOME + no global git config, so identity fallback is exercised.
TEST_HOME="$(new_scratch_dir)"
export HOME="$TEST_HOME"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# init_git_store <dir> — fixture store as a git repo with one setup commit.
init_git_store() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$FIXTURE_STORE/." "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=setup -c user.email=setup@example.com add -A
  git -C "$dir" -c user.name=setup -c user.email=setup@example.com commit -q -m "setup: seed fixture store"
}

# make_remote_and_clone <scratch> — seeds a bare remote from the fixture
# store and clones it to <scratch>/clone; echoes nothing, sets REMOTE/CLONE.
make_remote_and_clone() {
  local scratch="$1"
  REMOTE="$scratch/remote.git"
  git init -q --bare "$REMOTE"
  local seed="$scratch/seed"
  init_git_store "$seed"
  # Reindex + commit via store-sync itself so index.json/stats.json exist
  # before the clone is made (same trick as test-store-sync.sh assertion 8)
  # — otherwise every later commit would see them as brand-new files.
  "$STORE_SYNC" "$seed" commit -m "seed: reindex" >/dev/null 2>&1 || true
  git -C "$seed" remote add origin "$REMOTE"
  git -C "$seed" -c user.name=setup -c user.email=setup@example.com push -q origin HEAD:refs/heads/main
  git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
  CLONE="$scratch/clone"
  git clone -q "$REMOTE" "$CLONE"
  git -C "$CLONE" checkout -q -B main origin/main 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# assertion 1: non-git store dir refuses (exit 2)
# ---------------------------------------------------------------------------

scratch1="$(new_scratch_dir)"
store1="$scratch1/store"
mkdir -p "$store1"
cp -R "$FIXTURE_STORE/." "$store1"

out1="$("$STORE_LAND" "$store1" 2>&1)"
status1=$?

if [ "$status1" -eq 2 ] && printf '%s' "$out1" | grep -qF "not a git repo"; then
  pass "store-land refuses a non-git store dir (exit 2)"
else
  fail "store-land did not refuse a non-git store dir (exit=$status1)"
  echo "$out1"
fi

# ---------------------------------------------------------------------------
# assertion 2: on the default branch, delegates to store-sync tick
# ---------------------------------------------------------------------------

scratch2="$(new_scratch_dir)"
make_remote_and_clone "$scratch2"

out2="$("$STORE_LAND" "$CLONE" 2>&1)"
status2=$?

if [ "$status2" -eq 0 ] && printf '%s' "$out2" | grep -qF "store-sync: tick"; then
  pass "store-land on the default branch delegates to store-sync tick"
else
  fail "store-land on main did not delegate to tick (exit=$status2)"
  echo "$out2"
fi

# ---------------------------------------------------------------------------
# assertion 3: branch-merge happy path
# ---------------------------------------------------------------------------

scratch3="$(new_scratch_dir)"
make_remote_and_clone "$scratch3"
clone3="$CLONE"
remote3="$REMOTE"

git -C "$clone3" checkout -q -b debrief-work
person3="$(ls "$clone3/people"/*.md | head -1)"
echo "- **[told-by-user]** landed-from-branch test fact" >> "$person3"

out3="$("$STORE_LAND" "$clone3" 2>&1)"
status3=$?

branch3="$(git -C "$clone3" symbolic-ref --short -q HEAD)"
remote_has3="$(git -C "$remote3" log --oneline main 2>/dev/null | head -5)"
remote_file3="$(git -C "$remote3" show "main:people/$(basename "$person3")" 2>/dev/null)"

if [ "$status3" -eq 0 ] \
  && printf '%s' "$out3" | grep -qF "store-land: landed debrief-work -> main pushed=yes" \
  && [ "$branch3" = "main" ] \
  && printf '%s' "$remote_file3" | grep -qF "landed-from-branch test fact"
then
  pass "branch-merge happy path lands the work branch into main and pushes"
else
  fail "branch-merge happy path did not land as expected (exit=$status3, branch=$branch3)"
  echo "$out3"
  echo "$remote_has3"
fi

merge_commit3="$(git -C "$clone3" rev-parse -q --verify HEAD^2 2>/dev/null || true)"
if [ -n "$merge_commit3" ]; then
  pass "landing produced a real --no-ff merge commit (HEAD has two parents)"
else
  fail "landing did not produce a merge commit"
fi

# ---------------------------------------------------------------------------
# assertion 4: merge conflict aborts and leaves the repo as found
# ---------------------------------------------------------------------------

scratch4="$(new_scratch_dir)"
make_remote_and_clone "$scratch4"
a4="$CLONE"
remote4="$REMOTE"
b4="$scratch4/clone-b"
git clone -q "$remote4" "$b4"
git -C "$b4" checkout -q -B main origin/main 2>/dev/null || true

# B pushes one version of notes.txt to main.
echo "B's line" > "$b4/notes.txt"
git -C "$b4" add notes.txt
git -C "$b4" -c user.name=b -c user.email=b@example.com commit -q -m "B: add notes.txt"
git -C "$b4" -c user.name=b -c user.email=b@example.com push -q origin HEAD:main

# A, on a work branch, writes a conflicting notes.txt.
git -C "$a4" checkout -q -b conflict-work
echo "A's line" > "$a4/notes.txt"
git -C "$a4" add notes.txt
git -C "$a4" -c user.name=a -c user.email=a@example.com commit -q -m "A: add conflicting notes.txt"

head_before4="$(git -C "$a4" rev-parse HEAD)"

out4="$("$STORE_LAND" "$a4" 2>&1)"
status4=$?

branch4="$(git -C "$a4" symbolic-ref --short -q HEAD)"
head_after4="$(git -C "$a4" rev-parse HEAD)"
porcelain4="$(git -C "$a4" status --porcelain)"

if [ "$status4" -eq 1 ] && printf '%s' "$out4" | grep -qF "FAIL: merge conflict — resolve by hand"; then
  pass "merge conflict fails with the FAIL line and exit 1"
else
  fail "merge conflict did not fail as expected (exit=$status4)"
  echo "$out4"
fi

if [ "$branch4" = "conflict-work" ] && [ "$head_before4" = "$head_after4" ] \
  && [ -z "$porcelain4" ] && [ ! -e "$a4/.git/MERGE_HEAD" ]
then
  pass "conflict abort returns to the work branch with a clean tree and no merge in progress"
else
  fail "conflict abort left the repo dirty (branch=$branch4, porcelain='$porcelain4')"
fi

# ---------------------------------------------------------------------------
# assertion 5: invalid store on a work branch — exit 1, nothing merged
# ---------------------------------------------------------------------------

scratch5="$(new_scratch_dir)"
make_remote_and_clone "$scratch5"
clone5="$CLONE"
remote5="$REMOTE"

remote_head5_before="$(git -C "$remote5" rev-parse main)"
git -C "$clone5" checkout -q -b invalid-work
person5="$(ls "$clone5/people"/*.md | head -1)"
sed -i.bak '/^schema_version:/d' "$person5"
rm -f "${person5}.bak"

out5="$("$STORE_LAND" "$clone5" 2>&1)"
status5=$?
remote_head5_after="$(git -C "$remote5" rev-parse main)"
branch5="$(git -C "$clone5" symbolic-ref --short -q HEAD)"

if [ "$status5" -eq 1 ] \
  && printf '%s' "$out5" | grep -qF "nothing merged" \
  && [ "$remote_head5_before" = "$remote_head5_after" ] \
  && [ "$branch5" = "invalid-work" ]
then
  pass "invalid store on a work branch refuses (exit 1) and merges nothing"
else
  fail "invalid store on a work branch did not refuse as expected (exit=$status5, branch=$branch5)"
  echo "$out5"
fi

# ---------------------------------------------------------------------------
# assertion 6: init-store.sh installs the pre-commit hook, idempotently
# ---------------------------------------------------------------------------

scratch6="$(new_scratch_dir)"
store6="$scratch6/store"
mkdir -p "$store6"
git -C "$store6" init -q -b main

init_out6="$("$INIT_STORE" "$store6" 2>&1)"
init_status6=$?
hook6="$store6/.git/hooks/pre-commit"

if [ "$init_status6" -eq 0 ] \
  && printf '%s' "$init_out6" | grep -qF "OK: installed pre-commit validation hook" \
  && [ -x "$hook6" ] \
  && grep -qF "$HOOK_MARKER" "$hook6"
then
  pass "init-store.sh installs the marked, executable pre-commit hook into a git store"
else
  fail "init-store.sh did not install the pre-commit hook (exit=$init_status6)"
  echo "$init_out6"
fi

init_out6b="$("$INIT_STORE" "$store6" 2>&1)"
if ! printf '%s' "$init_out6b" | grep -qF "OK: installed pre-commit validation hook"; then
  pass "init-store.sh re-run does not reinstall over our own hook"
else
  fail "init-store.sh re-run printed the install line again"
  echo "$init_out6b"
fi

scratch6c="$(new_scratch_dir)"
store6c="$scratch6c/store"
mkdir -p "$store6c"
git -C "$store6c" init -q -b main
mkdir -p "$store6c/.git/hooks"
printf '#!/bin/sh\nexit 0\n' > "$store6c/.git/hooks/pre-commit"
chmod +x "$store6c/.git/hooks/pre-commit"

init_out6c="$("$INIT_STORE" "$store6c" 2>&1)"
if printf '%s' "$init_out6c" | grep -qF "SKIP: existing pre-commit hook is not spomni's" \
  && ! grep -qF "$HOOK_MARKER" "$store6c/.git/hooks/pre-commit"
then
  pass "init-store.sh leaves a foreign pre-commit hook alone and prints a SKIP line"
else
  fail "init-store.sh touched a foreign pre-commit hook or printed no SKIP line"
  echo "$init_out6c"
fi

# ---------------------------------------------------------------------------
# assertion 7: hook blocks an invalid commit and allows a valid one
# (machinery via SPOMNI_MACHINERY -> this checkout)
# ---------------------------------------------------------------------------

scratch7="$(new_scratch_dir)"
store7="$scratch7/store"
mkdir -p "$store7"
cp -R "$FIXTURE_STORE/." "$store7"
git -C "$store7" init -q -b main
"$INIT_STORE" "$store7" > /dev/null 2>&1

# Invalid: hand-write a person file with no provenance tag on a Facts bullet.
cat > "$store7/people/hand-written.md" <<'EOF'
---
schema_version: 1.4.0
name: Hand Written
---

## Facts

- an untagged fact with no provenance label
EOF

git -C "$store7" add -A
commit_out7a="$(cd "$store7" && SPOMNI_MACHINERY="$REPO_ROOT" git -c user.name=t -c user.email=t@example.com commit -m "invalid" 2>&1)"
commit_status7a=$?

if [ "$commit_status7a" -ne 0 ] \
  && printf '%s' "$commit_out7a" | grep -qF "commit blocked" \
  && printf '%s' "$commit_out7a" | grep -qF "hand-written.md"
then
  pass "pre-commit hook blocks a commit with an invalid hand-written store file"
else
  fail "pre-commit hook did not block the invalid commit (exit=$commit_status7a)"
  echo "$commit_out7a"
fi

# Fix the file; the commit must now pass.
cat > "$store7/people/hand-written.md" <<'EOF'
---
schema_version: 1.4.0
name: Hand Written
---

## Facts

- **[told-by-user]** a properly tagged fact (2026-08-31)
EOF

git -C "$store7" add -A
commit_out7b="$(cd "$store7" && SPOMNI_MACHINERY="$REPO_ROOT" git -c user.name=t -c user.email=t@example.com commit -m "valid" 2>&1)"
commit_status7b=$?

if [ "$commit_status7b" -eq 0 ]; then
  pass "pre-commit hook allows a valid commit"
else
  fail "pre-commit hook blocked a valid commit (exit=$commit_status7b)"
  echo "$commit_out7b"
fi

# ---------------------------------------------------------------------------
# assertion 8: missing machinery — hook warns but allows the commit
# ---------------------------------------------------------------------------

echo "extra" > "$store7/notes.txt"
git -C "$store7" add -A
commit_out8="$(cd "$store7" && env -u SPOMNI_MACHINERY git -c user.name=t -c user.email=t@example.com commit -m "no machinery" 2>&1)"
commit_status8=$?

if [ "$commit_status8" -eq 0 ] \
  && printf '%s' "$commit_out8" | grep -qF "no machinery checkout found"
then
  pass "hook warns but allows the commit when no machinery is discoverable"
else
  fail "hook did not warn-and-allow without machinery (exit=$commit_status8)"
  echo "$commit_out8"
fi

# ---------------------------------------------------------------------------
# assertion 9: base-machine layout — store at <machinery>/data/store, no
# SPOMNI_MACHINERY and no ./machinery; hook finds the machinery by walking
# up to the grandparent and still validates.
# ---------------------------------------------------------------------------

scratch9="$(new_scratch_dir)"
mach9="$scratch9/machinery-copy"
mkdir -p "$mach9/data"
# Minimal machinery skeleton: point packages/ at the real checkout so
# <mach9>/packages/core/scripts/validate-store.sh resolves.
ln -s "$REPO_ROOT/packages" "$mach9/packages"

store9="$mach9/data/store"
mkdir -p "$store9"
cp -R "$FIXTURE_STORE/." "$store9"
git -C "$store9" init -q -b main
"$INIT_STORE" "$store9" > /dev/null 2>&1

# Invalid file: the hook must discover the machinery via the grandparent
# walk and block the commit.
cat > "$store9/people/hand-written.md" <<'EOF'
---
schema_version: 1.4.0
name: Hand Written
---

## Facts

- an untagged fact with no provenance label
EOF

git -C "$store9" add -A
commit_out9a="$(cd "$store9" && env -u SPOMNI_MACHINERY git -c user.name=t -c user.email=t@example.com commit -m "invalid" 2>&1)"
commit_status9a=$?

if [ "$commit_status9a" -ne 0 ] \
  && printf '%s' "$commit_out9a" | grep -qF "commit blocked" \
  && printf '%s' "$commit_out9a" | grep -qF "hand-written.md"
then
  pass "hook discovers machinery via grandparent walk (store at <machinery>/data/store) and blocks an invalid commit"
else
  fail "hook did not block the invalid commit via grandparent discovery (exit=$commit_status9a)"
  echo "$commit_out9a"
fi

# Fix the file; the commit must now pass with the same discovery path.
cat > "$store9/people/hand-written.md" <<'EOF'
---
schema_version: 1.4.0
name: Hand Written
---

## Facts

- **[told-by-user]** a properly tagged fact (2026-08-31)
EOF

git -C "$store9" add -A
commit_out9b="$(cd "$store9" && env -u SPOMNI_MACHINERY git -c user.name=t -c user.email=t@example.com commit -m "valid" 2>&1)"
commit_status9b=$?

if [ "$commit_status9b" -eq 0 ]; then
  pass "hook allows a valid commit via grandparent discovery"
else
  fail "hook blocked a valid commit via grandparent discovery (exit=$commit_status9b)"
  echo "$commit_out9b"
fi

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -eq 0 ]; then
  exit 0
else
  exit 1
fi
