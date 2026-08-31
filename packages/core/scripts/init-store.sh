#!/usr/bin/env bash
# init-store.sh — create (or verify) a spomni store's directory layout.
#
# Usage: init-store.sh <store-dir>
#
# Idempotent, never deletes:
#   - creates inbox/, people/, interactions/, wakeups/ if missing
#   - writes <store-dir>/README.md if absent (private-store reminder)
#   - writes <store-dir>/CLAUDE.md if absent (cold-session bootstrap, from
#     templates/data-repo-CLAUDE.md)
#   - if the store is its own git repo, installs the pre-commit validation
#     hook (templates/store-pre-commit-hook.sh) when .git/hooks/pre-commit
#     is absent; an existing hook without our marker line is left alone
#   - runs build-index.sh + build-stats.sh so index.json/stats.json exist
#     even when the store is empty
#   - runs validate-store.sh and exits with its status
#
# Refuses (exit 2, "FAIL:") if <store-dir> already has a .git that is the
# SAME repository as this code checkout — that's someone about to commit
# their people into the public repo.
#
# Portable to bash 3.2: no associative arrays, no mapfile.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ "$#" -lt 1 ]; then
    echo "usage: init-store.sh <store-dir>" >&2
    exit 2
fi

store_dir="$1"

# Safety check: refuse if store-dir is a git repo that is the same
# repository as this code checkout.
if [ -e "$store_dir/.git" ]; then
    store_toplevel="$(git -C "$store_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$store_toplevel" ] && [ "$store_toplevel" = "$REPO_ROOT" ]; then
        echo "FAIL: ${store_dir} is the code checkout itself (same git repo as ${REPO_ROOT}) — refusing to initialize a store here; other people's data must never live inside the public code repo"
        exit 2
    fi
fi

mkdir -p "$store_dir"
abs_store_dir="$(cd "$store_dir" && pwd)"

for sub in inbox people interactions wakeups; do
    mkdir -p "$abs_store_dir/$sub"
done

if [ ! -e "$abs_store_dir/README.md" ]; then
    cat > "$abs_store_dir/README.md" <<'EOF'
This is your private Spomni store — your contact graph, kept only for you.
Keep it in a private repo or private directory, never checked in anywhere public.
Never place it inside the Spomni code checkout — code and data are separate.
EOF
fi

if [ ! -e "$abs_store_dir/CLAUDE.md" ]; then
    cp "$SCRIPT_DIR/../templates/data-repo-CLAUDE.md" "$abs_store_dir/CLAUDE.md"
fi

# Pre-commit validation hook: when the store is its own git repo (the
# refusal check above already excluded the code checkout), install
# templates/store-pre-commit-hook.sh as .git/hooks/pre-commit. Idempotent:
# our hook carries the marker line "# spomni-store-validate-hook v1"; an
# existing hook without that marker is not ours and is left alone.
HOOK_TEMPLATE="$SCRIPT_DIR/../templates/store-pre-commit-hook.sh"
HOOK_MARKER="# spomni-store-validate-hook v1"
if [ -d "$abs_store_dir/.git" ] && [ -f "$HOOK_TEMPLATE" ]; then
    hook_path="$abs_store_dir/.git/hooks/pre-commit"
    if [ ! -e "$hook_path" ]; then
        mkdir -p "$abs_store_dir/.git/hooks"
        cp "$HOOK_TEMPLATE" "$hook_path"
        chmod +x "$hook_path"
        echo "OK: installed pre-commit validation hook"
    elif ! grep -qF "$HOOK_MARKER" "$hook_path"; then
        echo "SKIP: existing pre-commit hook is not spomni's — left untouched"
    fi
fi

"$SCRIPT_DIR/build-index.sh" "$abs_store_dir"
"$SCRIPT_DIR/build-stats.sh" "$abs_store_dir"

set +e
"$SCRIPT_DIR/validate-store.sh" "$abs_store_dir"
validate_status=$?
set -e

if [ "$validate_status" -eq 0 ]; then
    echo "OK: store initialized at ${abs_store_dir}"
fi

exit "$validate_status"
