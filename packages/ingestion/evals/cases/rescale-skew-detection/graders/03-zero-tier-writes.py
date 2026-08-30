#!/usr/bin/env python3
"""03-zero-tier-writes.py — T3 grader for rescale-skew-detection.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from this case's prompt.md, NOT from any run's
output — per the eval-case contract's golden-tests-before-prompts rule):
Step 4 only presents a batch — no confirm/adjust action occurs in this
session (the prompt never asks for one), so `relationship-scoring.md`'s
"Zero unconfirmed tier writes" rule means every `people/*.md` file must
come out of this run byte-identical to its `before/` original. This
grader derives the expected `before/` directory from its own file
location (`packages/ingestion/evals/cases/rescale-skew-detection/before/
people/`) rather than the `RA_EVAL_BEFORE_DIR` env var, so it's
self-contained regardless of the runner's temp-copy layout.
"""

import filecmp
import glob
import os
import sys

CASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEFORE_PEOPLE_DIR = os.path.join(CASE_DIR, "before", "people")


def main():
    if len(sys.argv) < 2:
        print("usage: 03-zero-tier-writes.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_people_dir = os.path.join(worked, "people")

    failures = []

    before_files = {os.path.basename(p) for p in glob.glob(os.path.join(BEFORE_PEOPLE_DIR, "*.md"))}
    worked_files = {os.path.basename(p) for p in glob.glob(os.path.join(worked_people_dir, "*.md"))}

    if worked_files != before_files:
        failures.append(
            f"people/ file set changed: before={sorted(before_files)} worked={sorted(worked_files)}"
        )

    for fname in sorted(before_files & worked_files):
        before_path = os.path.join(BEFORE_PEOPLE_DIR, fname)
        worked_path = os.path.join(worked_people_dir, fname)
        if not filecmp.cmp(before_path, worked_path, shallow=False):
            failures.append(f"people/{fname}: modified — presenting a batch must write zero tiers")

    if failures:
        print("FAIL:")
        for line in failures:
            print(f"  - {line}")
        return 1

    print("PASS: every people/*.md file is byte-identical to before/ — zero tier writes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
