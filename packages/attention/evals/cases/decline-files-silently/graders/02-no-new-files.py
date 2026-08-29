#!/usr/bin/env python3
"""02-no-new-files.py — T3 grader for decline-files-silently.

$1 = path to the worked store dir (the fixture copy after the skill ran).
$2 = path to eval-run-skill.sh's result.json (unused).

This IS plan 21's silent-decline guardrail, pinned as executable code: per
packages/attention/skills/event-confirm/SKILL.md's step 4 ("After the
dismiss write completes, this skill goes silent: no retry, no follow-up
question, no new artifact beyond the dismissed wake-up file itself") and
wakeup.md's Notes ("The dismissed wake-up file is itself the record: no
retry, no second artifact"), a decline run must touch exactly one file --
the target wake-up card -- and create or delete nothing else anywhere in
the store. This checks the whole store's file set (not just wakeups/), so a
stray file dropped anywhere -- a duplicate proposal, a log, a note under
people/ or interactions/ -- also fails this grader.

Hand-derived expectation: the seeded fixture at
packages/attention/tests/fixtures/event-confirm/decline-files-silently/
contains exactly 6 files (people/theo-bramwell.md, 4 interactions/*.md,
wakeups/2026-08-31-theo-bramwell.md); the worked store must contain exactly
that same file set, no more, no fewer.
"""

import os
import sys

TARGET = os.path.join("wakeups", "2026-08-31-theo-bramwell.md")


def fixture_dir():
    before_dir = os.environ.get("RA_EVAL_BEFORE_DIR", "")
    if before_dir:
        return before_dir
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(
        os.path.join(
            here, "..", "..", "..", "..", "tests", "fixtures", "event-confirm",
            "decline-files-silently",
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
        print("usage: 02-no-new-files.py <worked-store-dir> [result.json]")
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
        print(f"FAIL: decline run created new/extra file(s), expected silence: {extra}")
        return 1

    if missing:
        print(f"FAIL: worked store is missing seeded file(s): {missing}")
        return 1

    # Every file except the target wake-up must be byte-identical to the
    # seed -- the decline only ever touches its own card.
    mismatched = []
    for rel in sorted(worked_files):
        if rel == TARGET:
            continue
        with open(os.path.join(worked, rel), "rb") as f:
            worked_bytes = f.read()
        with open(os.path.join(fixture, rel), "rb") as f:
            fixture_bytes = f.read()
        if worked_bytes != fixture_bytes:
            mismatched.append(rel)

    if mismatched:
        print(f"FAIL: file(s) other than {TARGET} were modified: {mismatched}")
        return 1

    print(
        f"PASS: worked store contains exactly the seeded {len(worked_files)} file(s), "
        f"only {TARGET} changed"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
