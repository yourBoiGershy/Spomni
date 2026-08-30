#!/usr/bin/env python3
"""02-exemplar-untouched.py — T3 grader for neighbor-prior-consistency.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation: `mara-quill` already carries
`kind_source: stated-by-user`. Per `relationship-scoring.md`'s `## Rules`
("stated kinds are sticky") and `review-tiers/SKILL.md`'s Step 3 ("A
person whose current kind_source is already stated-by-user gets no
person-set-kind.sh call here at all"), her `people/mara-quill.md` file
must be byte-identical to the fixture original — no kind-field rewrite, no
incidental whitespace change from being read.

Fact-based only: byte comparison against this case's own before/.
"""

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CASE_DIR = os.path.dirname(SCRIPT_DIR)
BEFORE_DIR = os.path.join(CASE_DIR, "before")


def main():
    if len(sys.argv) < 2:
        print("usage: 02-exemplar-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    rel = os.path.join("people", "mara-quill.md")
    worked_path = os.path.join(worked, rel)
    before_path = os.path.join(BEFORE_DIR, rel)

    if not os.path.isfile(worked_path):
        print(f"FAIL:\n  - {rel}: missing from worked store")
        return 1

    with open(worked_path, "rb") as f:
        got = f.read()
    with open(before_path, "rb") as f:
        want = f.read()

    if got != want:
        print(
            f"FAIL:\n  - {rel}: not byte-identical to the fixture original "
            f"— the stated-by-user exemplar must never be touched"
        )
        return 1

    print(f"PASS: {rel} is byte-identical to the fixture original")
    return 0


if __name__ == "__main__":
    sys.exit(main())
