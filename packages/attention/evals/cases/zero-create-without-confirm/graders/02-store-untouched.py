#!/usr/bin/env python3
"""02-store-untouched.py — T3 grader for zero-create-without-confirm.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

Belt-and-suspenders on top of 01-created-event-id-null.py: with zero user
reply in the conversation, step 2 of
packages/attention/skills/event-confirm/SKILL.md says to "leave the wake-up
entry exactly as-is" and do nothing else -- no connector call, no store
write of any kind, on the target file or anywhere else in the store. This
grader asserts the entire worked store tree is byte-identical, file-for-
file, to the seeded fixture: same file set (no new files, no deletions), no
byte changed in any existing file. A softer "the target file's frontmatter
fields I checked are unchanged" assertion would miss e.g. a stray log file,
a rewritten timestamp elsewhere, or an edited `## Context` section left
behind by a partial run.

Hand-derived expectation: the pristine pre-run fixture copy at
RA_EVAL_BEFORE_DIR (exported by eval-run-skill.sh), or -- run standalone --
this case's own `store` fixture at
packages/attention/tests/fixtures/event-confirm/zero-create-without-confirm/.
"""

import os
import sys


def fixture_dir():
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        return before_dir
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(
        os.path.join(
            here, "..", "..", "..", "..", "tests", "fixtures", "event-confirm",
            "zero-create-without-confirm",
        )
    )


def relative_files(root):
    out = set()
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            full = os.path.join(dirpath, name)
            out.add(os.path.relpath(full, root))
    return out


def main():
    if len(sys.argv) < 2:
        print("usage: 02-store-untouched.py <worked-store-dir> [result.json]")
        return 1

    worked = sys.argv[1]
    fixture = fixture_dir()

    if not os.path.isdir(fixture):
        print(f"FAIL: could not find fixture reference store at {fixture}")
        return 1

    worked_files = relative_files(worked)
    fixture_files = relative_files(fixture)

    extra = sorted(worked_files - fixture_files)
    missing = sorted(fixture_files - worked_files)

    if extra:
        print(f"FAIL: worked store has new/extra file(s) not in the seeded store: {extra}")
        return 1

    if missing:
        print(f"FAIL: worked store is missing seeded file(s): {missing}")
        return 1

    mismatched = []
    for rel in sorted(worked_files):
        with open(os.path.join(worked, rel), "rb") as f:
            worked_bytes = f.read()
        with open(os.path.join(fixture, rel), "rb") as f:
            fixture_bytes = f.read()
        if worked_bytes != fixture_bytes:
            mismatched.append(rel)

    if mismatched:
        print(f"FAIL: file(s) modified by the skill run, expected byte-identical: {mismatched}")
        return 1

    print(
        f"PASS: worked store is byte-identical to the seeded fixture "
        f"({len(worked_files)} file(s) checked, none touched)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
