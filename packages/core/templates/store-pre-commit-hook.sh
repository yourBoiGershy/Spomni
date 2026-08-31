#!/usr/bin/env bash
# spomni-store-validate-hook v1
# store-pre-commit-hook.sh — pre-commit hook TEMPLATE for a private Spomni
# data repo. Installed into <store>/.git/hooks/pre-commit by init-store.sh
# and store-sync.sh (both check the marker line above before touching an
# existing hook — never overwrite a hook that isn't ours).
#
# On every `git commit` in the store it locates the machinery checkout and
# runs validate-store.sh against the repo root, blocking the commit (exit 1,
# validator output echoed) on errors.
#
# Machinery discovery order:
#   1. $SPOMNI_MACHINERY (path to the Spomni code checkout)
#   2. <repo-root>/machinery/ (the cloud-session clone convention)
#   3. give up: print a one-line warning and ALLOW the commit (exit 0) —
#      never brick the user's repo over a missing code checkout.
#
# Dependency-light: bash + whatever validate-store.sh itself needs.
# Portable to bash 3.2: no associative arrays, no mapfile.

set -eu

repo_root="$(git rev-parse --show-toplevel)"

machinery=""
if [ -n "${SPOMNI_MACHINERY:-}" ] && [ -d "${SPOMNI_MACHINERY}" ]; then
    machinery="${SPOMNI_MACHINERY}"
elif [ -d "${repo_root}/machinery" ]; then
    machinery="${repo_root}/machinery"
fi

if [ -z "$machinery" ]; then
    echo "spomni pre-commit: no machinery checkout found (set SPOMNI_MACHINERY or clone the code into ./machinery) — skipping store validation, commit allowed"
    exit 0
fi

validator="${machinery}/packages/core/scripts/validate-store.sh"
if [ ! -f "$validator" ]; then
    echo "spomni pre-commit: ${validator} not found — skipping store validation, commit allowed"
    exit 0
fi

set +e
validate_out="$(bash "$validator" "$repo_root" 2>&1)"
validate_status=$?
set -e

if [ "$validate_status" -ne 0 ]; then
    echo "$validate_out"
    echo "spomni pre-commit: validate-store.sh reported errors — commit blocked"
    exit 1
fi

exit 0
