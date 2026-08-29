#!/usr/bin/env python3
"""02-never-demoted.py — T3 grader for the tier-drift-upward eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

This IS the never-demote guardrail, executed as code, not softened into a
"tier is still dormant" field check: per specs/tier-drift.md ("Tier changes
are filed exclusively by packages/ingestion, only after the user confirms")
and CLAUDE.md's no-guilt/draft-never-send spirit applied to self-classification,
the detector must not touch people/owen-marsh.md AT ALL. The assertion is
byte-identity of the whole file against the pristine fixture copy, not just
that the `tier:` line still reads `dormant` -- a detector that rewrote
unrelated fields (last-touch, Personal details prose) while leaving `tier:`
alone would still be violating "attention never writes person.md" and should
fail this grader too.

Hand-derived expected bytes: the untouched fixture copy at
RA_EVAL_BEFORE_DIR (exported by eval-run-skill.sh as the pre-run store path)
-- or, if run standalone outside the runner, this case's own store field
resolved relative to the repo root.
"""

import os
import sys


def fixture_person_path():
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        return os.path.join(before_dir, "people", "owen-marsh.md")
    # Fallback for standalone invocation: derive the fixture path from this
    # case's known store field (packages/attention/tests/fixtures/
    # tier-drift-upward), relative to this grader's own location.
    here = os.path.dirname(os.path.abspath(__file__))
    repo_relative = os.path.join(
        here, "..", "..", "..", "tests", "fixtures", "tier-drift-upward",
        "people", "owen-marsh.md",
    )
    return os.path.normpath(repo_relative)


def main():
    if len(sys.argv) < 2:
        print("usage: 02-never-demoted.py <worked-store-dir> [result.json]")
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
