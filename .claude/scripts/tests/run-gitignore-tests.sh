#!/usr/bin/env bash
# .claude/scripts/tests/run-gitignore-tests.sh
#
# Asserts the .gitignore carve-outs added by PR #32 (after PR #31 merged red
# because the blanket `*.log` rule swallowed
# packages/ingestion/tests/fixtures/.../outbox/delivered.log) actually hold:
#
#   *.log
#   !packages/*/tests/fixtures/**/*.log
#   !packages/*/evals/cases/**/*.log
#
# 1. every currently-tracked fixture/eval-case path is NOT ignored
# 2. planted probe paths under those carve-out globs are NOT ignored
# 3. a negative control proves the *.log rule still bites elsewhere (so
#    removing the `!` lines would make assertion 2 fail rather than
#    assertion 2 trivially passing because nothing is actually ignored)
# 4. data/ stays ignored except data/README.md (sanity, unrelated rule)
#
# Uses `git check-ignore -q --no-index <path>` throughout; --no-index means
# tracked status never masks the rule, and check-ignore does not require the
# path to exist on disk, so probe paths are never written to the working
# tree.
#
# bash 3.2 portable (no mapfile, no declare -A, no `sed -i ''`, no `date -v`)
# — must run under macOS's stock /bin/bash and Ubuntu's bash.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1

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

# is_ignored <path> -> exit 0 if git says it's ignored, 1 otherwise
is_ignored() {
    git check-ignore -q --no-index -- "$1"
}

# ===========================================================================
# 1. tracked fixtures/eval-cases must not be ignored
# ===========================================================================
tracked_ignored=""
tracked_count=0
while IFS= read -r p; do
    [ -z "$p" ] && continue
    tracked_count=$((tracked_count + 1))
    if is_ignored "$p"; then
        tracked_ignored="$tracked_ignored $p"
    fi
done <<EOF
$(git ls-files -- 'packages/*/tests/fixtures/**' 'packages/*/evals/cases/**')
EOF

if [ "$tracked_count" -eq 0 ]; then
    fail "tracked fixtures: found 0 tracked paths under packages/*/tests/fixtures or packages/*/evals/cases — check the glob"
elif [ -z "$tracked_ignored" ]; then
    pass "tracked fixtures: all $tracked_count tracked fixture/eval-case paths are not ignored"
else
    fail "tracked fixtures: these tracked paths ARE ignored:$tracked_ignored"
fi

# ===========================================================================
# 2. planted probe paths under the carve-out globs must not be ignored
# ===========================================================================
PROBE1="packages/core/tests/fixtures/__gitignore_probe__/x.log"
PROBE2="packages/ingestion/tests/fixtures/__gitignore_probe__/deep/outbox/delivered.log"
PROBE3="packages/attention/evals/cases/__gitignore_probe__/y.log"

for probe in "$PROBE1" "$PROBE2" "$PROBE3"; do
    if is_ignored "$probe"; then
        fail "planted probe: $probe is ignored (carve-out rule not matching)"
    else
        pass "planted probe: $probe is not ignored"
    fi
done

# ===========================================================================
# 3. negative control: the *.log rule still bites outside the carve-outs
# ===========================================================================
NEG1="packages/core/scripts/__probe__.log"
NEG2=".claude/logs/x.log"

for neg in "$NEG1" "$NEG2"; do
    if is_ignored "$neg"; then
        pass "negative control: $neg is ignored (confirms *.log rule is active)"
    else
        fail "negative control: $neg is NOT ignored — *.log rule not active, test would pass vacuously"
    fi
done

# ===========================================================================
# 4. sanity: data/ carve-out unaffected
#
# data/store is a live symlink in this working tree (out-of-repo private
# store); check-ignore refuses pathspecs that traverse a symlink ("beyond a
# symbolic link"), so probe data/config/x.md — a real (non-symlinked)
# directory under the same `data/*` / `!data/README.md` rule — instead.
# ===========================================================================
if is_ignored "data/config/x.md"; then
    pass "data/ sanity: data/config/x.md is ignored"
else
    fail "data/ sanity: data/config/x.md is NOT ignored"
fi

if is_ignored "data/README.md"; then
    fail "data/ sanity: data/README.md IS ignored (should be carved out)"
else
    pass "data/ sanity: data/README.md is not ignored"
fi

# ===========================================================================
echo ""
echo "SUMMARY: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
