#!/usr/bin/env bash
# 01-stated-holds.sh — T3 grader for jane-doe-tier-correction.
# $1 = path to the worked store dir (the before/ copy after the skill ran).
#
# Hand-derived from the `signals/feedback.jsonl` line this case was
# generated from (jane-doe, tier-correction, to=close, ts=2026-08-20T14:05:00Z): after the run,
# `people/jane-doe.md` must still carry `tier: close` and
# `tier_source: stated-by-user` — the correction must stick against
# review-tiers' Step 3 judge/write pass, per relationship-scoring.md's
# sticky-stated rules.

set -u

worked="${1:-}"
person_file="${worked}/people/jane-doe.md"

if [ ! -f "$person_file" ]; then
    echo "FAIL: missing ${person_file}"
    exit 1
fi

fail=0

if ! grep -qF 'tier: close' "$person_file"; then
    echo "FAIL: tier: close not found in ${person_file}"
    fail=1
fi

if ! grep -qF 'tier_source: stated-by-user' "$person_file"; then
    echo "FAIL: tier_source: stated-by-user not found in ${person_file}"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: jane-doe's tier=close (tier_source: stated-by-user) held"
    exit 0
fi

exit 1
