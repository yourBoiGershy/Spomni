#!/usr/bin/env bash
# packages/core/tests/run-user-skills-tests.sh
#
# Asserts that packages/core/scripts/link-user-skills.sh:
#   bash packages/core/scripts/link-user-skills.sh <data-dir> [--target-dir <dir>] [--prune] [--dry-run]
#
#   1. fresh link of two skills -> both "linked", symlinks resolve, exit 0
#   2. idempotent rerun -> "kept", exit 0
#   3. conflict: pre-existing real directory at target name -> "skip", other
#      skill still linked, exit 1
#   4. --prune after deleting a skill's SKILL.md -> "pruned", link gone
#   5. --dry-run on a fresh target -> no links created, exit 0
#   6. empty skills dir -> the no-user-skills message, exit 0
#   7. name-mismatch frontmatter ("name:" != directory name) -> skip + exit 1
#
# Every test case passes --target-dir into its own mktemp -d scratch dir —
# never the real $HOME/.claude/skills.
#
# bash 3.2 portable (no associative arrays, no mapfile, no <<< here-strings
# relied on for state outside a loop that needs it) — this must run under
# macOS's stock /bin/bash. Resolves all paths relative to the repo root, so
# it can be invoked from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

LINKER="$REPO_ROOT/packages/core/scripts/link-user-skills.sh"

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

# --- linker must exist ---
if [ ! -f "$LINKER" ]; then
  echo "SKIP: $LINKER not found — cannot run user-skills tests yet."
  echo ""
  echo "SUMMARY: 0 passed, 0 failed, linker missing"
  exit 1
fi

if [ ! -x "$LINKER" ]; then
  echo "FAIL: $LINKER exists but is not executable"
  echo ""
  echo "SUMMARY: 0 passed, 1 failed"
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- fixture helper: writes a valid skill dir under <data-dir>/skills/<name> ---
make_skill() {
  # $1 = data-dir, $2 = skill name (also used as the frontmatter name:)
  local data_dir="$1" name="$2"
  mkdir -p "$data_dir/skills/$name"
  cat > "$data_dir/skills/$name/SKILL.md" <<EOF
---
name: $name
description: test fixture skill "$name"
---

# $name

Test fixture skill body.
EOF
}

# =============================================================================
# case 1: fresh link of two skills -> both "linked", symlinks resolve, exit 0
# =============================================================================

echo ""
echo "--- case 1: fresh link of two skills ---"

C1_DATA="$TMP_ROOT/case1-data"
C1_TARGET="$TMP_ROOT/case1-target"
mkdir -p "$C1_DATA" "$C1_TARGET"
make_skill "$C1_DATA" alpha-skill
make_skill "$C1_DATA" beta-skill

c1_out="$("$LINKER" "$C1_DATA" --target-dir "$C1_TARGET" 2>&1)"
c1_status=$?

if [ "$c1_status" -eq 0 ]; then
  pass "case 1: exits 0 on a fresh link of two valid skills"
else
  fail "case 1: exited $c1_status (expected 0): $c1_out"
fi

if printf '%s' "$c1_out" | grep -qF "linked alpha-skill" && printf '%s' "$c1_out" | grep -qF "linked beta-skill"; then
  pass "case 1: prints 'linked <name>' for both skills"
else
  fail "case 1: did not print 'linked' for both skills: $c1_out"
fi

if [ -L "$C1_TARGET/alpha-skill" ] && [ -L "$C1_TARGET/beta-skill" ]; then
  pass "case 1: both target entries are symlinks"
else
  fail "case 1: target entries are not both symlinks"
fi

if [ "$(cd "$C1_TARGET/alpha-skill" && pwd -P)" = "$(cd "$C1_DATA/skills/alpha-skill" && pwd -P)" ] \
  && [ "$(cd "$C1_TARGET/beta-skill" && pwd -P)" = "$(cd "$C1_DATA/skills/beta-skill" && pwd -P)" ]; then
  pass "case 1: both symlinks resolve to their data-dir skill directories"
else
  fail "case 1: symlinks do not resolve to the expected skill directories"
fi

# =============================================================================
# case 2: idempotent rerun -> "kept", exit 0
# =============================================================================

echo ""
echo "--- case 2: idempotent rerun ---"

c2_out="$("$LINKER" "$C1_DATA" --target-dir "$C1_TARGET" 2>&1)"
c2_status=$?

if [ "$c2_status" -eq 0 ]; then
  pass "case 2: rerun exits 0"
else
  fail "case 2: rerun exited $c2_status (expected 0): $c2_out"
fi

if printf '%s' "$c2_out" | grep -qF "kept alpha-skill" && printf '%s' "$c2_out" | grep -qF "kept beta-skill"; then
  pass "case 2: rerun prints 'kept <name>' for both already-correct skills"
else
  fail "case 2: rerun did not print 'kept' for both skills: $c2_out"
fi

# =============================================================================
# case 3: conflict — pre-existing real directory at target name
# =============================================================================

echo ""
echo "--- case 3: conflict with a pre-existing real directory ---"

C3_DATA="$TMP_ROOT/case3-data"
C3_TARGET="$TMP_ROOT/case3-target"
mkdir -p "$C3_DATA" "$C3_TARGET"
make_skill "$C3_DATA" conflict-skill
make_skill "$C3_DATA" clean-skill
mkdir -p "$C3_TARGET/conflict-skill"
echo "not a symlink" > "$C3_TARGET/conflict-skill/not-a-skill.txt"

c3_out="$("$LINKER" "$C3_DATA" --target-dir "$C3_TARGET" 2>&1)"
c3_status=$?

if [ "$c3_status" -eq 1 ]; then
  pass "case 3: exits 1 when a real directory conflicts with a skill name"
else
  fail "case 3: exited $c3_status (expected 1): $c3_out"
fi

if printf '%s' "$c3_out" | grep -qF "skip conflict-skill (conflict:"; then
  pass "case 3: prints the 'skip <name> (conflict: ...)' line"
else
  fail "case 3: did not print the expected skip/conflict line: $c3_out"
fi

if [ -d "$C3_TARGET/conflict-skill" ] && [ ! -L "$C3_TARGET/conflict-skill" ] \
  && [ -f "$C3_TARGET/conflict-skill/not-a-skill.txt" ]; then
  pass "case 3: the conflicting real directory is left untouched"
else
  fail "case 3: the conflicting directory was modified or removed"
fi

if [ -L "$C3_TARGET/clean-skill" ]; then
  pass "case 3: the non-conflicting skill is still linked"
else
  fail "case 3: the non-conflicting skill was not linked despite the other's conflict"
fi

# =============================================================================
# case 4: --prune after deleting a skill's SKILL.md -> "pruned", link gone
# =============================================================================

echo ""
echo "--- case 4: --prune removes a link whose SKILL.md disappeared ---"

C4_DATA="$TMP_ROOT/case4-data"
C4_TARGET="$TMP_ROOT/case4-target"
mkdir -p "$C4_DATA" "$C4_TARGET"
make_skill "$C4_DATA" doomed-skill
make_skill "$C4_DATA" survivor-skill

"$LINKER" "$C4_DATA" --target-dir "$C4_TARGET" > /dev/null 2>&1

rm -f "$C4_DATA/skills/doomed-skill/SKILL.md"

c4_out="$("$LINKER" "$C4_DATA" --target-dir "$C4_TARGET" --prune 2>&1)"
c4_status=$?

if printf '%s' "$c4_out" | grep -qF "pruned doomed-skill"; then
  pass "case 4: --prune prints 'pruned doomed-skill'"
else
  fail "case 4: --prune did not print the expected pruned line: $c4_out"
fi

if [ ! -e "$C4_TARGET/doomed-skill" ]; then
  pass "case 4: the pruned symlink no longer exists in the target dir"
else
  fail "case 4: the pruned symlink is still present"
fi

if [ -L "$C4_TARGET/survivor-skill" ]; then
  pass "case 4: the still-valid skill's link survives the prune"
else
  fail "case 4: the still-valid skill's link was removed by prune"
fi

# =============================================================================
# case 5: --dry-run on a fresh target -> no links created, exit 0
# =============================================================================

echo ""
echo "--- case 5: --dry-run makes no filesystem changes ---"

C5_DATA="$TMP_ROOT/case5-data"
C5_TARGET="$TMP_ROOT/case5-target"
mkdir -p "$C5_DATA" "$C5_TARGET"
make_skill "$C5_DATA" dryrun-skill

c5_out="$("$LINKER" "$C5_DATA" --target-dir "$C5_TARGET" --dry-run 2>&1)"
c5_status=$?

if [ "$c5_status" -eq 0 ]; then
  pass "case 5: --dry-run exits 0"
else
  fail "case 5: --dry-run exited $c5_status (expected 0): $c5_out"
fi

if printf '%s' "$c5_out" | grep -qF "would-link dryrun-skill"; then
  pass "case 5: --dry-run prints 'would-link dryrun-skill'"
else
  fail "case 5: --dry-run did not print the expected would-link line: $c5_out"
fi

if [ ! -e "$C5_TARGET/dryrun-skill" ]; then
  pass "case 5: --dry-run created no entry in the target dir"
else
  fail "case 5: --dry-run created an entry in the target dir despite --dry-run"
fi

# =============================================================================
# case 6: empty skills dir -> the no-user-skills message, exit 0
# =============================================================================

echo ""
echo "--- case 6: empty skills dir ---"

C6_DATA="$TMP_ROOT/case6-data"
C6_TARGET="$TMP_ROOT/case6-target"
mkdir -p "$C6_DATA/skills" "$C6_TARGET"

c6_out="$("$LINKER" "$C6_DATA" --target-dir "$C6_TARGET" 2>&1)"
c6_status=$?

if [ "$c6_status" -eq 0 ]; then
  pass "case 6: empty skills dir exits 0"
else
  fail "case 6: empty skills dir exited $c6_status (expected 0): $c6_out"
fi

if printf '%s' "$c6_out" | grep -qF "no user skills found in $C6_DATA/skills"; then
  pass "case 6: prints the expected no-user-skills message"
else
  fail "case 6: did not print the expected no-user-skills message: $c6_out"
fi

# --- missing data-dir entirely -> exit 2 ---

echo ""
echo "--- case 6b: missing data-dir ---"

C6B_TARGET="$TMP_ROOT/case6b-target"
mkdir -p "$C6B_TARGET"
c6b_out="$("$LINKER" "$TMP_ROOT/does-not-exist" --target-dir "$C6B_TARGET" 2>&1)"
c6b_status=$?

if [ "$c6b_status" -eq 2 ]; then
  pass "case 6b: a missing data-dir exits 2"
else
  fail "case 6b: a missing data-dir exited $c6b_status (expected 2): $c6b_out"
fi

# =============================================================================
# case 7: name-mismatch frontmatter -> skip + exit 1
# =============================================================================

echo ""
echo "--- case 7: SKILL.md name: field mismatches its directory name ---"

C7_DATA="$TMP_ROOT/case7-data"
C7_TARGET="$TMP_ROOT/case7-target"
mkdir -p "$C7_DATA/skills/mismatched-dir" "$C7_TARGET"
cat > "$C7_DATA/skills/mismatched-dir/SKILL.md" <<'EOF'
---
name: totally-different-name
description: frontmatter name does not match its directory
---

# mismatched-dir

Test fixture skill body.
EOF
make_skill "$C7_DATA" good-skill

c7_out="$("$LINKER" "$C7_DATA" --target-dir "$C7_TARGET" 2>&1)"
c7_status=$?

if [ "$c7_status" -eq 1 ]; then
  pass "case 7: exits 1 when a skill's frontmatter name mismatches its directory name"
else
  fail "case 7: exited $c7_status (expected 1): $c7_out"
fi

if printf '%s' "$c7_out" | grep -qF "skip mismatched-dir (name mismatch)"; then
  pass "case 7: prints 'skip <name> (name mismatch)'"
else
  fail "case 7: did not print the expected name-mismatch skip line: $c7_out"
fi

if [ -L "$C7_TARGET/good-skill" ]; then
  pass "case 7: the well-formed sibling skill is still linked despite the mismatch"
else
  fail "case 7: the well-formed sibling skill was not linked"
fi

rm -rf "$TMP_ROOT"
trap - EXIT

echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
