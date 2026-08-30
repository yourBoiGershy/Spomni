#!/usr/bin/env python3
"""02-skip-ledger.py — T3 grader for
review-tiers-zero-writes-without-confirm.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md, NOT from any run's
output): the transcript has exactly two EXPLICIT skip actions —
sol-abernathy and june-abernathy — each of which, per SKILL.md's Step 4
("Skip appends one line to the skip ledger... format: <slug>\\t<ISO 8601
Z>"), must append exactly one tab-separated `<slug>\\t<timestamp>` line to
`data-ingestion/review-skips.log` (bound to `./store/data-ingestion/
review-skips.log` for this eval workspace per prompt.md). otto-brandvold
and hal-torrance were never reached before the session ended — per the
same Step 4 text ("Ending the session mid-batch is treated as a skip for
everyone not yet acted on — never logged"), session-end is NOT logged, so
neither of their slugs may appear anywhere in the ledger. The ledger
started empty (before/), so the worked ledger must contain exactly two
non-empty lines total.
"""

import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")

EXPECTED_SLUGS = {"sol-abernathy", "june-abernathy"}
FORBIDDEN_SLUGS = {"otto-brandvold", "hal-torrance"}

LINE_RE = re.compile(r"^([a-z0-9-]+)\t(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)$")


def main():
    if len(sys.argv) < 2:
        print("usage: 02-skip-ledger.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    ledger_rel = os.path.join("data-ingestion", "review-skips.log")
    worked_ledger = os.path.join(worked, ledger_rel)
    before_ledger = os.path.join(BEFORE_DIR, ledger_rel)

    failures = []

    if not os.path.isfile(worked_ledger):
        print(f"FAIL: {ledger_rel} missing from worked store")
        return 1

    with open(before_ledger) as f:
        before_lines = [ln for ln in f.read().splitlines() if ln.strip()]
    if before_lines:
        failures.append(
            f"{ledger_rel}: before/ fixture was not empty as this test "
            f"assumes ({len(before_lines)} pre-existing lines) — fixture bug"
        )

    with open(worked_ledger) as f:
        lines = [ln for ln in f.read().splitlines() if ln.strip()]

    if len(lines) != 2:
        failures.append(
            f"{ledger_rel}: {len(lines)} non-empty line(s), expected exactly "
            f"2 (one per explicit skip — sol-abernathy, june-abernathy)"
        )

    seen_slugs = []
    for line in lines:
        m = LINE_RE.match(line)
        if not m:
            failures.append(
                f"{ledger_rel}: line {line!r} does not match "
                f"'<slug>\\t<ISO 8601 Z>'"
            )
            continue
        slug, _ts = m.group(1), m.group(2)
        seen_slugs.append(slug)
        if slug in FORBIDDEN_SLUGS:
            failures.append(
                f"{ledger_rel}: line for '{slug}' — this person was never "
                f"reached before the session ended (no explicit skip), so "
                f"session-end must NOT be logged for them"
            )

    if sorted(set(seen_slugs) & EXPECTED_SLUGS) != sorted(EXPECTED_SLUGS):
        failures.append(
            f"{ledger_rel}: expected exactly one line each for "
            f"{sorted(EXPECTED_SLUGS)}, got slugs {seen_slugs}"
        )

    # No duplicate lines for either expected slug.
    for slug in EXPECTED_SLUGS:
        count = seen_slugs.count(slug)
        if count > 1:
            failures.append(
                f"{ledger_rel}: '{slug}' appears {count} times, expected "
                f"exactly once"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: skip ledger has exactly two lines, sol-abernathy and "
        "june-abernathy each once, correct format; no line for "
        "otto-brandvold or hal-torrance"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
