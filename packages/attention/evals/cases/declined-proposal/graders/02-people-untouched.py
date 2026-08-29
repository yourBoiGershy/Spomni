#!/usr/bin/env python3
"""02-people-untouched.py — T3 grader for the declined-proposal eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Same never-demote guardrail as tier-drift-upward's 02-never-demoted.py,
applied to the declined-proposal fixture: a declined proposal never
triggers an automatic tier write (specs/tier-drift.md's confirmation-path
step 2), so people/owen-marsh.md must be byte-identical to the fixture
regardless of whether the detector correctly suppresses re-proposing.
"""

import os
import sys


def fixture_person_path():
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        return os.path.join(before_dir, "people", "owen-marsh.md")
    here = os.path.dirname(os.path.abspath(__file__))
    repo_relative = os.path.join(
        here, "..", "..", "..", "tests", "fixtures", "declined-proposal",
        "people", "owen-marsh.md",
    )
    return os.path.normpath(repo_relative)


def main():
    if len(sys.argv) < 2:
        print("usage: 02-people-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_person = os.path.join(worked, "people", "owen-marsh.md")
    fixture_person = fixture_person_path()

    if not os.path.isfile(worked_person):
        print(f"FAIL: worked store is missing people/owen-marsh.md at {worked_person}")
        return 1

    if not os.path.isfile(fixture_person):
        print(f"FAIL: could not find fixture reference copy at {fixture_person}")
        return 1

    with open(worked_person, "rb") as f:
        worked_bytes = f.read()
    with open(fixture_person, "rb") as f:
        fixture_bytes = f.read()

    if worked_bytes != fixture_bytes:
        print(
            f"FAIL: people/owen-marsh.md was modified by the detector run "
            f"-- expected byte-identical to fixture at {fixture_person}"
        )
        return 1

    print("PASS: people/owen-marsh.md is byte-identical to the fixture -- tier never written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
