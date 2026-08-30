#!/usr/bin/env python3
"""03-never-writes-people.py — T3 grader for the tier-drift-by-kind eval case.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

This IS the never-write-people/never-write-priors guardrail, executed as
code (same shape as tier-drift-upward's 02-never-demoted.py): per
specs/tier-drift.md ("Tier changes are filed exclusively by
packages/ingestion, only after the user confirms") the detector must not
touch any `people/*.md` file, and per the spec's judgment-verdict section
("Attention writes no `tier`/`kind`/`user-model.md` anywhere" -- this
case's brief) it must not create a `user-model.md` either, even though the
fixture starts without one and the prompt asks the detector to judge
without priors. The assertion is byte-identity of every people/*.md file
against the pristine fixture copy (RA_EVAL_BEFORE_DIR), not just that no
new person file appears -- a detector that rewrote an existing person's
unrelated fields while proposing a drift wake-up would still be violating
"attention never writes person.md" and should fail this grader too.
"""

import glob
import os
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: 03-never-writes-people.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")

    if not before_dir:
        # Fallback for standalone invocation outside the T3 runner: derive
        # the fixture path from this case's known store field.
        here = os.path.dirname(os.path.abspath(__file__))
        before_dir = os.path.normpath(
            os.path.join(
                here, "..", "..", "..", "tests", "fixtures", "tier-drift-by-kind",
            )
        )

    worked_people_dir = os.path.join(worked, "people")
    before_people_dir = os.path.join(before_dir, "people")

    if not os.path.isdir(worked_people_dir):
        print(f"FAIL: worked store is missing people/ at {worked_people_dir}")
        return 1
    if not os.path.isdir(before_people_dir):
        print(f"FAIL: could not find fixture reference people/ at {before_people_dir}")
        return 1

    before_files = sorted(glob.glob(os.path.join(before_people_dir, "*.md")))
    if not before_files:
        print(f"FAIL: fixture reference people/ at {before_people_dir} is empty")
        return 1

    for before_path in before_files:
        name = os.path.basename(before_path)
        worked_path = os.path.join(worked_people_dir, name)
        if not os.path.isfile(worked_path):
            print(f"FAIL: worked store is missing people/{name}")
            return 1
        with open(before_path, "rb") as f:
            before_bytes = f.read()
        with open(worked_path, "rb") as f:
            worked_bytes = f.read()
        if before_bytes != worked_bytes:
            print(
                f"FAIL: people/{name} was modified by the detector run -- "
                f"expected byte-identical to the fixture"
            )
            return 1

    worked_names = {os.path.basename(p) for p in glob.glob(os.path.join(worked_people_dir, "*.md"))}
    before_names = {os.path.basename(p) for p in before_files}
    extra = worked_names - before_names
    if extra:
        print(f"FAIL: detector created new people/ file(s): {sorted(extra)}")
        return 1

    user_model_path = os.path.join(worked, "user-model.md")
    if os.path.isfile(user_model_path):
        print(
            "FAIL: detector created data-store/user-model.md -- attention "
            "must judge without priors when no user-model exists, never "
            "author one itself"
        )
        return 1

    print(
        f"PASS: all {len(before_files)} people/*.md byte-identical to the "
        f"fixture, no new person file, no user-model.md created"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
