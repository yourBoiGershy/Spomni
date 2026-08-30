#!/usr/bin/env python3
"""01-no-tier-writes.py — T3 grader for
review-tiers-zero-writes-without-confirm.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md, NOT from any run's
output — per the eval-case contract's golden-tests-before-prompts rule):
the simulated transcript has zero confirm/adjust replies — two explicit
skips (sol-abernathy, june-abernathy) and two people never reached before
the session ended (otto-brandvold, hal-torrance). Per
`packages/ingestion/skills/review-tiers/SKILL.md`'s Step 4 ("Zero tier
writes without confirmation... A skip writes nothing... Ending the session
mid-batch is treated as a skip for everyone not yet acted on"), none of the
four person files may gain a `tier` value, and — since this case performs
no judge step of its own (Steps 1-3 already ran off-screen per prompt.md)
— every OTHER frontmatter field (including the already-derived `kind`/
`kind_note`/`kind_source`/`kind_updated` fields on three of the four) and
the body must also be byte-identical to `before/`, since Step 4 alone,
given zero confirm/adjust actions, has no reason to touch any person file
at all.
"""

import os
import sys

PEOPLE = [
    "sol-abernathy.md",
    "june-abernathy.md",
    "otto-brandvold.md",
    "hal-torrance.md",
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")


def main():
    if len(sys.argv) < 2:
        print("usage: 01-no-tier-writes.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    failures = []

    for fname in PEOPLE:
        worked_path = os.path.join(worked, "people", fname)
        before_path = os.path.join(BEFORE_DIR, "people", fname)

        if not os.path.isfile(worked_path):
            failures.append(f"people/{fname}: missing from worked store")
            continue

        with open(worked_path) as f:
            got = f.read()
        with open(before_path) as f:
            want = f.read()

        if got != want:
            failures.append(
                f"people/{fname}: byte content changed — no confirm/adjust "
                f"utterance for this person in the transcript, so this file "
                f"(including tier and any already-derived kind fields) must "
                f"stay exactly as it was in before/"
            )

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print(
        "PASS: no tier written on any of the four people, and every person "
        "file is byte-identical to before/ (kind fields untouched too)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
