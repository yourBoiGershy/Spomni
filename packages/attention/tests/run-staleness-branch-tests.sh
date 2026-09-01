#!/usr/bin/env bash
# packages/attention/tests/run-staleness-branch-tests.sh
#
# Test suite for packages/attention/scripts/staleness.sh check 4 — stranded
# unmerged work branches in the store's own git repo. Infrastructure for the
# *noticing* cost of an unlanded branch: a claude/* or worktree-* branch
# whose tip sat unmerged for over 24h yields exactly one staleness wake-up;
# merged or young branches yield none; re-run never duplicates while one is
# pending. No fetch is involved — the fixture repos are fully local.
#
# Scenarios (all built against mktemp scratch stores copied from
# packages/core/fixtures/store, each turned into a real temp git repo with
# committer dates pinned via GIT_COMMITTER_DATE and time pinned via --now):
#   1. stranded claude/* and worktree-* branches older than 24h -> stale,
#      exactly one pending wake-up each (status/origin/signal-type/[[self]]),
#      / in the branch name sanitized to - in the source-signal; a
#      remote-only refs/remotes/origin/claude/* branch counts too
#   2. re-run same inputs -> already-pending, still exactly one per branch
#   3. already-merged claude/* branch -> skipped silently, no wake-up
#   4. branch younger than 24h -> ok, no wake-up
#   5. non-git store -> check prints nothing, creates nothing
#   6. --dry-run on a stranded store -> stale reported, zero files created
#
# bash 3.2 portable (no associative arrays, no mapfile) — must run under
# macOS's stock /bin/bash, invocable from anywhere.

set -u

# --- resolve repo root relative to this script, not the caller's cwd ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

STALENESS="$REPO_ROOT/packages/attention/scripts/staleness.sh"
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

for req in "$STALENESS" "$FIXTURE_STORE"; do
  if [ ! -e "$req" ]; then
    fail "required path missing: $req"
    summary_and_exit
  fi
done

if ! command -v git >/dev/null 2>&1; then
  fail "git is required to run this suite but was not found on PATH"
  summary_and_exit
fi

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'staleness-branch-test')"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

NOW="2026-08-30T12:00:00Z"
OLD_DATE="2026-08-27T12:00:00Z"   # > 24h before NOW -> stranded if unmerged
YOUNG_DATE="2026-08-30T06:00:00Z" # < 24h before NOW -> ok

# Empty sync-data-dir shared by every scenario so sections 2/3 stay silent.
SYNC_DIR="$TMP_ROOT/sync-data-empty"
mkdir -p "$SYNC_DIR"

# new_store <dir> — a fresh scratch store copied from the committed fixture;
# heartbeats/ removed so section 1 stays silent and only check 4 speaks.
new_store() {
  local dir="$1"
  mkdir -p "$dir"
  cp -R "$FIXTURE_STORE/." "$dir/"
  rm -rf "$dir/heartbeats"
}

# git_commit <dir> <iso-date> <msg> — empty commit with a pinned date
git_commit() {
  GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
    git -C "$1" -c commit.gpgsign=false commit -q --allow-empty -m "$3"
}

# new_store_repo <dir> — new_store plus git init with one commit on main
new_store_repo() {
  local dir="$1"
  new_store "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" checkout -q -b main
  git_commit "$dir" "$OLD_DATE" "init"
}

# count_wakeups <dir> <name> — count of wakeups/*.md whose frontmatter has
# source-signal: staleness:<name>
count_wakeups() {
  local dir="$1" name="$2"
  grep -l "^source-signal: staleness:${name}\$" "$dir"/wakeups/*.md 2>/dev/null | wc -l | tr -d ' '
}

# =============================================================================
# Scenario 1: stranded branches older than 24h -> stale, one wake-up each
# =============================================================================

S1_DIR="$TMP_ROOT/s1-stranded"
new_store_repo "$S1_DIR"

# local claude/* branch, one unmerged commit older than 24h
git -C "$S1_DIR" checkout -q -b claude/test-branch
git_commit "$S1_DIR" "$OLD_DATE" "stranded follow-ups"

# local worktree-* branch, same shape
git -C "$S1_DIR" checkout -q -b worktree-fix main
git_commit "$S1_DIR" "$OLD_DATE" "stranded worktree"

# remote-only claude/* branch: an unmerged commit known solely as
# refs/remotes/origin/claude/remote-only (no local branch, no fetch)
git -C "$S1_DIR" checkout -q -b tmp-remote main
git_commit "$S1_DIR" "$OLD_DATE" "stranded remote"
S1_REMOTE_SHA="$(git -C "$S1_DIR" rev-parse tmp-remote)"
git -C "$S1_DIR" update-ref refs/remotes/origin/claude/remote-only "$S1_REMOTE_SHA"
git -C "$S1_DIR" checkout -q main
git -C "$S1_DIR" branch -q -D tmp-remote

s1_out="$("$STALENESS" "$S1_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" 2>&1)"
s1_status=$?

if [ "$s1_status" -eq 0 ]; then
  pass "stranded: exits 0"
else
  fail "stranded: exited $s1_status: $s1_out"
fi

if printf '%s\n' "$s1_out" | grep -q '^staleness: unmerged-branch-claude-test-branch stale'; then
  pass "stranded: claude/test-branch reported stale (slash sanitized to -)"
else
  fail "stranded: expected 'unmerged-branch-claude-test-branch stale', got: $s1_out"
fi

if printf '%s\n' "$s1_out" | grep -q '^staleness: unmerged-branch-worktree-fix stale'; then
  pass "stranded: worktree-fix reported stale"
else
  fail "stranded: expected 'unmerged-branch-worktree-fix stale', got: $s1_out"
fi

if printf '%s\n' "$s1_out" | grep -q '^staleness: unmerged-branch-claude-remote-only stale'; then
  pass "stranded: remote-only origin branch reported stale"
else
  fail "stranded: expected 'unmerged-branch-claude-remote-only stale', got: $s1_out"
fi

S1_COUNT="$(count_wakeups "$S1_DIR" "unmerged-branch-claude-test-branch")"
if [ "$S1_COUNT" = "1" ]; then
  pass "stranded: exactly one wake-up for claude/test-branch"
else
  fail "stranded: expected exactly 1 wake-up for claude/test-branch, got $S1_COUNT"
fi

S1_WT_COUNT="$(count_wakeups "$S1_DIR" "unmerged-branch-worktree-fix")"
S1_RO_COUNT="$(count_wakeups "$S1_DIR" "unmerged-branch-claude-remote-only")"
if [ "$S1_WT_COUNT" = "1" ] && [ "$S1_RO_COUNT" = "1" ]; then
  pass "stranded: exactly one wake-up each for worktree-fix and claude/remote-only"
else
  fail "stranded: expected 1+1 wake-ups, got worktree-fix=$S1_WT_COUNT remote-only=$S1_RO_COUNT"
fi

S1_WAKEUP="$(grep -l "^source-signal: staleness:unmerged-branch-claude-test-branch\$" "$S1_DIR"/wakeups/*.md 2>/dev/null | head -n1)"
if [ -n "$S1_WAKEUP" ] && grep -q '^status: pending$' "$S1_WAKEUP" \
  && grep -q '^origin: standing$' "$S1_WAKEUP" \
  && grep -q '^signal-type: staleness$' "$S1_WAKEUP" \
  && grep -q '\[\[self\]\]' "$S1_WAKEUP" \
  && grep -q 'branch claude/test-branch in the data repo has unmerged work older than 24h' "$S1_WAKEUP"; then
  pass "stranded: wake-up has status: pending, origin: standing, signal-type: staleness, [[self]], why text"
else
  fail "stranded: wake-up file missing expected fields: $(cat "$S1_WAKEUP" 2>&1)"
fi

# =============================================================================
# Scenario 2: re-run same inputs -> already-pending, still exactly one each
# =============================================================================

s2_out="$("$STALENESS" "$S1_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" 2>&1)"
s2_status=$?

if [ "$s2_status" -eq 0 ] \
  && printf '%s\n' "$s2_out" | grep -q '^staleness: unmerged-branch-claude-test-branch already-pending' \
  && printf '%s\n' "$s2_out" | grep -q '^staleness: unmerged-branch-worktree-fix already-pending'; then
  pass "re-run: reports already-pending"
else
  fail "re-run: unexpected result (status=$s2_status): $s2_out"
fi

S2_COUNT="$(count_wakeups "$S1_DIR" "unmerged-branch-claude-test-branch")"
if [ "$S2_COUNT" = "1" ]; then
  pass "re-run: still exactly one wake-up for claude/test-branch"
else
  fail "re-run: expected exactly 1 wake-up, got $S2_COUNT"
fi

# =============================================================================
# Scenario 3: already-merged claude/* branch -> skipped silently, no wake-up
# =============================================================================

S3_DIR="$TMP_ROOT/s3-merged"
new_store_repo "$S3_DIR"
# tip identical to main's tip -> ancestor of the default branch -> merged
git -C "$S3_DIR" branch -q claude/merged

s3_out="$("$STALENESS" "$S3_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" 2>&1)"
s3_status=$?

if [ "$s3_status" -eq 0 ] && [ -z "$s3_out" ]; then
  pass "merged: exits 0 with no output (branch skipped silently)"
else
  fail "merged: expected silence (status=$s3_status): $s3_out"
fi

S3_COUNT="$(count_wakeups "$S3_DIR" "unmerged-branch-claude-merged")"
if [ "$S3_COUNT" = "0" ]; then
  pass "merged: no wake-up created"
else
  fail "merged: expected 0 wake-ups, got $S3_COUNT"
fi

# =============================================================================
# Scenario 4: branch younger than 24h -> ok, no wake-up
# =============================================================================

S4_DIR="$TMP_ROOT/s4-young"
new_store_repo "$S4_DIR"
git -C "$S4_DIR" checkout -q -b claude/young
git_commit "$S4_DIR" "$YOUNG_DATE" "fresh work"
git -C "$S4_DIR" checkout -q main

s4_out="$("$STALENESS" "$S4_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" 2>&1)"
s4_status=$?

if [ "$s4_status" -eq 0 ] && printf '%s\n' "$s4_out" | grep -q '^staleness: unmerged-branch-claude-young ok (tip committed'; then
  pass "young: reports ok with tip committerdate"
else
  fail "young: unexpected result (status=$s4_status): $s4_out"
fi

S4_COUNT="$(count_wakeups "$S4_DIR" "unmerged-branch-claude-young")"
if [ "$S4_COUNT" = "0" ]; then
  pass "young: no wake-up created"
else
  fail "young: expected 0 wake-ups, got $S4_COUNT"
fi

# =============================================================================
# Scenario 5: non-git store -> check prints nothing, creates nothing
# =============================================================================

S5_DIR="$TMP_ROOT/s5-non-git"
new_store "$S5_DIR"

S5_FILES_BEFORE="$(find "$S5_DIR/wakeups" -type f | sort)"

s5_out="$("$STALENESS" "$S5_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" 2>&1)"
s5_status=$?

if [ "$s5_status" -eq 0 ] && [ -z "$s5_out" ]; then
  pass "non-git store: exits 0 with no output"
else
  fail "non-git store: expected silence (status=$s5_status): $s5_out"
fi

S5_FILES_AFTER="$(find "$S5_DIR/wakeups" -type f | sort)"
if [ "$S5_FILES_BEFORE" = "$S5_FILES_AFTER" ]; then
  pass "non-git store: creates zero files"
else
  fail "non-git store: wakeups/ file listing changed"
fi

# =============================================================================
# Scenario 6: --dry-run on a stranded store -> stale reported, zero files
# =============================================================================

S6_DIR="$TMP_ROOT/s6-dry-run"
new_store_repo "$S6_DIR"
git -C "$S6_DIR" checkout -q -b claude/dry
git_commit "$S6_DIR" "$OLD_DATE" "stranded dry"
git -C "$S6_DIR" checkout -q main

S6_FILES_BEFORE="$(find "$S6_DIR/wakeups" -type f | sort)"

s6_out="$("$STALENESS" "$S6_DIR" --sync-data-dir "$SYNC_DIR" --now "$NOW" --dry-run 2>&1)"
s6_status=$?

if [ "$s6_status" -eq 0 ] && printf '%s\n' "$s6_out" | grep -q '^staleness: unmerged-branch-claude-dry stale (would create:'; then
  pass "dry-run: exits 0 and reports stale with 'would create:'"
else
  fail "dry-run: unexpected result (status=$s6_status): $s6_out"
fi

S6_FILES_AFTER="$(find "$S6_DIR/wakeups" -type f | sort)"
if [ "$S6_FILES_BEFORE" = "$S6_FILES_AFTER" ]; then
  pass "dry-run: creates zero files"
else
  fail "dry-run: wakeups/ file listing changed"
fi

summary_and_exit
