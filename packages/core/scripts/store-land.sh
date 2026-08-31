#!/usr/bin/env bash
# store-land.sh — the end-of-session "land" script for a git-backed spomni
# DATA repo: fold a work branch back into the default branch and push.
#
# Usage: store-land.sh <store-dir> [-m "<merge msg>"]
#
# Algorithm:
#   1. Refuse (exit 2) if <store-dir> is not a git repo (or is the code
#      checkout itself — same safety check as store-sync.sh).
#   2. Determine the current branch and the default branch (origin/HEAD,
#      falling back to main).
#   3. On the default branch: delegate to `store-sync.sh <store> tick` and
#      exit with its status — nothing to land.
#   4. On a work branch: validate-store.sh first (fail -> exit 1, nothing
#      merged), commit any uncommitted changes via `store-sync.sh commit`,
#      then fetch origin, checkout the default branch, pull it (ff-only,
#      falling back to a plain merge — NEVER rebase), merge the work branch
#      (--no-ff), push, and print one summary line:
#        store-land: landed <branch> -> <default> pushed=<yes|no>
#   5. On a merge conflict (pull or work-branch merge): abort the merge,
#      return to the work branch, print "FAIL: merge conflict — resolve by
#      hand" and exit 1 — the repo is left exactly as found.
#
# Git identity: merge commits fall back to -c user.name/-c user.email
# (${SPOMNI_GIT_NAME:-Spomni} / ${SPOMNI_GIT_EMAIL:-spomni@localhost}) when
# the store has no configured user.name — same rule as store-sync.sh.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

usage() {
    echo "usage: store-land.sh <store-dir> [-m \"<merge msg>\"]" >&2
}

if [ "$#" -lt 1 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    exit 2
fi

store_dir="$1"
shift

merge_msg=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -m)
            merge_msg="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ ! -e "$store_dir" ]; then
    echo "FAIL: store-dir ${store_dir} does not exist" >&2
    exit 2
fi

abs_store_dir="$(cd "$store_dir" && pwd -P)"

# Safety check: refuse if store-dir is the same git repository as this code
# checkout — other people's data must never live inside the public repo.
store_toplevel="$(git -C "$abs_store_dir" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$store_toplevel" ] && [ "$store_toplevel" = "$REPO_ROOT" ]; then
    echo "FAIL: ${abs_store_dir} is the code checkout itself (same git repo as ${REPO_ROOT}) — refusing to land a store here"
    exit 2
fi

if ! git -C "$abs_store_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "FAIL: ${abs_store_dir} is not a git repo — nothing to land"
    exit 2
fi

# git_ident — same fallback rule as store-sync.sh: explicit -c identity when
# the store has no configured user.name, never touches global config.
git_ident() {
    if [ -z "$(git -C "$abs_store_dir" config user.name || true)" ]; then
        printf -- '-c user.name=%s -c user.email=%s' \
            "${SPOMNI_GIT_NAME:-Spomni}" "${SPOMNI_GIT_EMAIL:-spomni@localhost}"
    fi
}

has_origin() {
    git -C "$abs_store_dir" remote get-url origin >/dev/null 2>&1
}

branch="$(git -C "$abs_store_dir" symbolic-ref --short -q HEAD || echo "")"
if [ -z "$branch" ]; then
    echo "FAIL: ${abs_store_dir} is not on a branch — resolve by hand, never rebase"
    exit 2
fi

# Default branch: origin/HEAD when set, else main.
default_branch=""
origin_head="$(git -C "$abs_store_dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)"
if [ -n "$origin_head" ]; then
    default_branch="${origin_head#refs/remotes/origin/}"
fi
if [ -z "$default_branch" ]; then
    default_branch="main"
fi

# --- On the default branch: nothing to land, just tick ---

if [ "$branch" = "$default_branch" ]; then
    "$SCRIPT_DIR/store-sync.sh" "$abs_store_dir" tick
    exit $?
fi

# --- On a work branch: validate first, nothing merged on failure ---

set +e
validate_out="$("$SCRIPT_DIR/validate-store.sh" "$abs_store_dir" 2>&1)"
validate_status=$?
set -e
if [ "$validate_status" -ne 0 ]; then
    echo "$validate_out"
    echo "FAIL: store-land refused — validate-store.sh reported errors; nothing merged"
    exit 1
fi

# Commit any uncommitted work on the branch via the sanctioned write path.
set +e
commit_out="$("$SCRIPT_DIR/store-sync.sh" "$abs_store_dir" commit -m "store: land ${branch} $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC")"
commit_status=$?
set -e
if [ "$commit_status" -ne 0 ]; then
    echo "$commit_out"
    echo "FAIL: store-land aborted — store-sync commit failed on ${branch}; nothing merged"
    exit 1
fi

if has_origin; then
    git -C "$abs_store_dir" fetch origin
fi

# abort_and_return — undo an in-progress merge and go back to the work
# branch, leaving the repo exactly as found.
abort_and_return() {
    git -C "$abs_store_dir" merge --abort >/dev/null 2>&1 || true
    git -C "$abs_store_dir" checkout -q "$branch" >/dev/null 2>&1 || true
}

if ! git -C "$abs_store_dir" checkout -q "$default_branch" 2>/dev/null; then
    echo "FAIL: could not check out ${default_branch} in ${abs_store_dir} — resolve by hand"
    exit 1
fi

# Pull the default branch: ff-only, fall back to a plain merge — NEVER rebase.
if has_origin && git -C "$abs_store_dir" rev-parse -q --verify "origin/${default_branch}" >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    if ! git -C "$abs_store_dir" $(git_ident) merge --ff-only "origin/${default_branch}" >/dev/null 2>&1; then
        # shellcheck disable=SC2046
        if ! git -C "$abs_store_dir" $(git_ident) merge --no-edit "origin/${default_branch}"; then
            abort_and_return
            echo "FAIL: merge conflict — resolve by hand"
            exit 1
        fi
    fi
fi

# Merge the work branch into the default branch (--no-ff, never rebase).
if [ -z "$merge_msg" ]; then
    merge_msg="store: land ${branch} into ${default_branch}"
fi
# shellcheck disable=SC2046
if ! git -C "$abs_store_dir" $(git_ident) merge --no-ff --no-edit -m "$merge_msg" "$branch"; then
    abort_and_return
    echo "FAIL: merge conflict — resolve by hand"
    exit 1
fi

pushed="no"
if has_origin; then
    if git -C "$abs_store_dir" push origin HEAD; then
        pushed="yes"
    else
        echo "FAIL: push rejected in ${abs_store_dir} — pull/merge by hand"
        exit 1
    fi
fi

echo "store-land: landed ${branch} -> ${default_branch} pushed=${pushed}"
