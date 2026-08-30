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
