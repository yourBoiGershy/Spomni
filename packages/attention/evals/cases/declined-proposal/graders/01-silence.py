#!/usr/bin/env python3
"""01-silence.py — T3 grader for the declined-proposal eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Hand-derived expectation (from
packages/attention/tests/fixtures/declined-proposal/wakeups/
2026-07-30-owen-marsh.md and expected/README.md, per
packages/attention/specs/tier-drift.md's declined-pairing suppression
rule): the fixture's owen-marsh has the same UPWARD-drift-qualifying
frequency signal as the tier-drift-upward sibling fixture, but a prior
`(owen-marsh, active)` tier-drift proposal was dismissed 30 days ago with
`dismiss-reason: not-this-signal-type` -- well inside the suppression
window. The detector must therefore produce silence: wakeups/ must contain
EXACTLY the one pre-existing dismissed file, byte-identical, and nothing
new.
"""

import glob
import os
import sys

EXPECTED_FILENAME = "2026-07-30-owen-marsh.md"


def main():
    if len(sys.argv) < 2:
        print("usage: 01-silence.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    worked_wakeups = os.path.join(worked, "wakeups")

    if not os.path.isdir(worked_wakeups):
        print(f"FAIL: no wakeups/ dir in worked store {worked}")
        return 1

    files = sorted(
        os.path.basename(p) for p in glob.glob(os.path.join(worked_wakeups, "*.md"))
    )

    if files != [EXPECTED_FILENAME]:
        print(
            f"FAIL: expected wakeups/ to contain exactly [{EXPECTED_FILENAME!r}], "
            f"found {files}"
        )
        return 1

    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        fixture_file = os.path.join(before_dir, "wakeups", EXPECTED_FILENAME)
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        fixture_file = os.path.normpath(
            os.path.join(
                here, "..", "..", "..", "tests", "fixtures", "declined-proposal",
                "wakeups", EXPECTED_FILENAME,
            )
        )

    if not os.path.isfile(fixture_file):
        print(f"FAIL: could not find fixture reference copy at {fixture_file}")
        return 1

    with open(os.path.join(worked_wakeups, EXPECTED_FILENAME), "rb") as f:
        worked_bytes = f.read()
    with open(fixture_file, "rb") as f:
        fixture_bytes = f.read()

    if worked_bytes != fixture_bytes:
        print(
            f"FAIL: existing wake-up {EXPECTED_FILENAME} was modified by the "
            f"detector run -- expected byte-identical to fixture at {fixture_file}"
        )
        return 1

    print("PASS: wakeups/ is silent -- only the pre-existing dismissed file remains, untouched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
