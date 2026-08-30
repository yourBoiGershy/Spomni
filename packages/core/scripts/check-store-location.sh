#!/usr/bin/env bash
# check-store-location.sh — flag store locations that risk leaking a
# private people-store into a public/synced place.
#
# Usage: check-store-location.sh <store-dir>
#
# Exit 0 + "OK: ..." when the location looks safe.
# Exit 1 + one "FAIL: ..." line per problem, for:
#   - the path resolves inside this code checkout's git worktree, EXCEPT
#     the conventional data/ subdir (gitignored there — data/store passes)
#   - the path is inside a known cloud-sync folder (iCloud/Dropbox/Google
#     Drive/OneDrive)
#   - the store dir's git remote (if any) matches this checkout's origin
#
# Exit 0 + "WARN: ..." (no FAIL) when the path is under ~/Documents,
# ~/Desktop, or ~/Downloads — those are TCC-protected on macOS and will
# silently break launchd-scheduled syncs; see docs/SETUP.md §1.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ "$#" -lt 1 ]; then
    echo "usage: check-store-location.sh <store-dir>" >&2
    exit 2
fi

store_dir="$1"

if [ ! -d "$store_dir" ]; then
    echo "FAIL: ${store_dir} does not exist or is not a directory"
    exit 1
fi

abs_store_dir="$(cd "$store_dir" && pwd -P)"

findings=0

# --- inside the code checkout's git worktree, except data/ ---
case "$abs_store_dir" in
    "$REPO_ROOT"/data|"$REPO_ROOT"/data/*)
        : # data/ subdir is gitignored — allowed
        ;;
    "$REPO_ROOT"|"$REPO_ROOT"/*)
        echo "FAIL: ${abs_store_dir} is inside the code checkout (${REPO_ROOT}) — other people's data must never live in the public code repo (except the gitignored data/ subdir)"
        findings=$((findings + 1))
        ;;
esac

# --- inside a known cloud-sync folder ---
case "$abs_store_dir" in
    */Library/Mobile\ Documents/*)
        echo "FAIL: ${abs_store_dir} is inside iCloud Drive (Library/Mobile Documents) — a synced folder is not safe for a private store"
        findings=$((findings + 1))
        ;;
    */Dropbox/*)
        echo "FAIL: ${abs_store_dir} is inside Dropbox — a synced folder is not safe for a private store"
        findings=$((findings + 1))
        ;;
    */Google\ Drive/*)
        echo "FAIL: ${abs_store_dir} is inside Google Drive — a synced folder is not safe for a private store"
        findings=$((findings + 1))
        ;;
    */OneDrive/*)
        echo "FAIL: ${abs_store_dir} is inside OneDrive — a synced folder is not safe for a private store"
        findings=$((findings + 1))
        ;;
    */Library/CloudStorage/*)
        echo "FAIL: ${abs_store_dir} is inside Library/CloudStorage — a synced folder is not safe for a private store"
        findings=$((findings + 1))
        ;;
esac

# --- git remote matches the code checkout's origin ---
if [ -e "$abs_store_dir/.git" ]; then
    store_origin="$(git -C "$abs_store_dir" remote get-url origin 2>/dev/null || true)"
    code_origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    if [ -n "$store_origin" ] && [ -n "$code_origin" ] && [ "$store_origin" = "$code_origin" ]; then
        echo "FAIL: ${abs_store_dir}'s git remote 'origin' (${store_origin}) is the same as the code checkout's — this would push people data to the public repo"
        findings=$((findings + 1))
    fi
fi

if [ "$findings" -ne 0 ]; then
    exit 1
fi

# --- TCC-protected folders: warn only ---
# Resolve $HOME the same way abs_store_dir was resolved (pwd -P) so a
# symlinked HOME (e.g. macOS /var -> /private/var) still matches.
abs_home="$HOME"
if [ -d "$HOME" ]; then
    abs_home="$(cd "$HOME" && pwd -P)"
fi

case "$abs_store_dir" in
    "$abs_home"/Documents|"$abs_home"/Documents/*)
        echo "WARN: ${abs_store_dir} is under ~/Documents — macOS TCC blocks launchd from accessing this folder unless Full Disk Access is granted; see docs/SETUP.md §1"
        ;;
    "$abs_home"/Desktop|"$abs_home"/Desktop/*)
        echo "WARN: ${abs_store_dir} is under ~/Desktop — macOS TCC blocks launchd from accessing this folder unless Full Disk Access is granted; see docs/SETUP.md §1"
        ;;
    "$abs_home"/Downloads|"$abs_home"/Downloads/*)
        echo "WARN: ${abs_store_dir} is under ~/Downloads — macOS TCC blocks launchd from accessing this folder unless Full Disk Access is granted; see docs/SETUP.md §1"
        ;;
    *)
        echo "OK: ${abs_store_dir} looks like a safe store location"
        ;;
esac

exit 0
